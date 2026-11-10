using Cali.Application.Identity;
using Cali.Domain.Identity;
using Dapper;
using Npgsql;

namespace Cali.Infrastructure.Persistence;

/// <summary>
/// Apple sign-in and refresh token rotation (db/010, ADR-071). Both operations are one READ COMMITTED transaction.
/// Rotation takes <c>FOR UPDATE</c> on the presented token and on its family, so two requests that present the same
/// token are serialized: exactly one rotates, the other then sees the token as used and revokes the family.
/// </summary>
public sealed class AuthStore(NpgsqlDataSource dataSource) : IAuthStore
{
    /// <summary>A nonce is kept this long past its token's expiry, which covers the validator's clock skew.</summary>
    internal static readonly TimeSpan NonceRetentionPadding = TimeSpan.FromMinutes(5);

    private const string PurgeNoncesSql = "DELETE FROM auth_apple_nonces WHERE expires_at < @now";

    private const string InsertNonceSql = """
        INSERT INTO auth_apple_nonces (nonce_sha256, expires_at) VALUES (@nonce, @expiresAt)
        ON CONFLICT (nonce_sha256) DO NOTHING
        """;

    // DO NOTHING (not DO UPDATE) so a returning user does not rewrite the row; a concurrent first sign-in for the
    // same subject waits on the unique index, so the SELECT below always sees the winner's committed row.
    private const string InsertUserSql = "INSERT INTO users (apple_subject) VALUES (@subject) ON CONFLICT (apple_subject) DO NOTHING";

    private const string SelectUserBySubjectSql = """
        SELECT id AS Id, display_name AS DisplayName, timezone AS Timezone, created_at AS CreatedAt, deleted_at AS DeletedAt
        FROM users WHERE apple_subject = @subject
        """;

    private const string SelectUserByIdSql = """
        SELECT id AS Id, display_name AS DisplayName, timezone AS Timezone, created_at AS CreatedAt, deleted_at AS DeletedAt
        FROM users WHERE id = @userId
        """;

    private const string InsertFamilySql = """
        INSERT INTO auth_refresh_families (id, user_id, device_id, created_at, expires_at)
        VALUES (@id, @userId, @deviceId, @now, @expiresAt)
        """;

    private const string InsertTokenSql = """
        INSERT INTO auth_refresh_tokens (family_id, token_sha256, created_at, expires_at)
        VALUES (@familyId, @hash, @now, @expiresAt)
        """;

    private const string SelectTokenSql = """
        SELECT t.id AS TokenId, t.family_id AS FamilyId, t.expires_at AS TokenExpiresAt, t.used_at AS UsedAt,
               f.user_id AS UserId, f.device_id AS DeviceId, f.expires_at AS FamilyExpiresAt, f.revoked_at AS RevokedAt
        FROM auth_refresh_tokens t
        JOIN auth_refresh_families f ON f.id = t.family_id
        WHERE t.token_sha256 = @hash
        FOR UPDATE OF t, f
        """;

    private const string MarkUsedSql = "UPDATE auth_refresh_tokens SET used_at = @now WHERE id = @id";

    private const string RevokeFamilySql = """
        UPDATE auth_refresh_families SET revoked_at = @now, revoked_reason = @reason
        WHERE id = @id AND revoked_at IS NULL
        """;

    public async Task<SignInOutcome> SignInWithAppleAsync(SignInRecord record, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(record);
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);

        await connection.ExecuteAsync(new CommandDefinition(
            PurgeNoncesSql, new { now = record.Now }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);

        var consumed = await connection.ExecuteAsync(new CommandDefinition(
            InsertNonceSql,
            new { nonce = record.NonceSha256, expiresAt = record.NonceExpiresAt + NonceRetentionPadding },
            transaction,
            cancellationToken: cancellationToken)).ConfigureAwait(false);
        if (consumed == 0)
        {
            await transaction.RollbackAsync(cancellationToken).ConfigureAwait(false);
            return new SignInOutcome(SignInStatus.NonceReused, null);
        }

        await connection.ExecuteAsync(new CommandDefinition(
            InsertUserSql, new { subject = record.AppleSubject }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
        var user = await connection.QuerySingleAsync<UserRow>(new CommandDefinition(
            SelectUserBySubjectSql, new { subject = record.AppleSubject }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
        if (user.DeletedAt is not null)
        {
            await transaction.RollbackAsync(cancellationToken).ConfigureAwait(false);
            return new SignInOutcome(SignInStatus.AccountUnavailable, null);
        }

        var familyId = Guid.NewGuid();
        var familyExpiresAt = record.Now + record.Lifetimes.Family;
        await connection.ExecuteAsync(new CommandDefinition(
            InsertFamilySql,
            new { id = familyId, userId = user.Id, deviceId = record.DeviceId, now = record.Now, expiresAt = familyExpiresAt },
            transaction,
            cancellationToken: cancellationToken)).ConfigureAwait(false);
        await connection.ExecuteAsync(new CommandDefinition(
            InsertTokenSql,
            new { familyId, hash = record.RefreshTokenSha256, now = record.Now, expiresAt = Earliest(record.Now + record.Lifetimes.Refresh, familyExpiresAt) },
            transaction,
            cancellationToken: cancellationToken)).ConfigureAwait(false);

        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return new SignInOutcome(SignInStatus.SignedIn, user.ToProfile());
    }

    public async Task<RotationOutcome> RotateAsync(RotationRecord record, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(record);
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);

        var token = await connection.QuerySingleOrDefaultAsync<TokenRow>(new CommandDefinition(
            SelectTokenSql, new { hash = record.CurrentSha256 }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
        if (token is null)
        {
            await transaction.RollbackAsync(cancellationToken).ConfigureAwait(false);
            return new RotationOutcome(RotationStatus.Unknown, null);
        }

        if (token.RevokedAt is not null)
        {
            await transaction.RollbackAsync(cancellationToken).ConfigureAwait(false);
            return new RotationOutcome(RotationStatus.Revoked, null);
        }

        if (token.UsedAt is not null)
        {
            // The token was already exchanged: either the legitimate client and a thief both hold the chain, or the
            // client retried after losing a response. The server cannot tell, so the whole family ends here.
            return await RevokeAsync(connection, transaction, token.FamilyId, "reuse", record.Now, RotationStatus.Reused, cancellationToken).ConfigureAwait(false);
        }

        if (token.TokenExpiresAt.ToUtc() <= record.Now || token.FamilyExpiresAt.ToUtc() <= record.Now)
        {
            await transaction.RollbackAsync(cancellationToken).ConfigureAwait(false);
            return new RotationOutcome(RotationStatus.Expired, null);
        }

        if (record.DeviceId is { } requested && token.DeviceId is { } bound && requested != bound)
        {
            await transaction.RollbackAsync(cancellationToken).ConfigureAwait(false);
            return new RotationOutcome(RotationStatus.DeviceMismatch, null);
        }

        var user = await connection.QuerySingleOrDefaultAsync<UserRow>(new CommandDefinition(
            SelectUserByIdSql, new { userId = token.UserId }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
        if (user is null || user.DeletedAt is not null)
        {
            return await RevokeAsync(connection, transaction, token.FamilyId, "user_unavailable", record.Now, RotationStatus.UserUnavailable, cancellationToken).ConfigureAwait(false);
        }

        await connection.ExecuteAsync(new CommandDefinition(
            MarkUsedSql, new { id = token.TokenId, now = record.Now }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
        await connection.ExecuteAsync(new CommandDefinition(
            InsertTokenSql,
            new
            {
                familyId = token.FamilyId,
                hash = record.NewSha256,
                now = record.Now,
                expiresAt = Earliest(record.Now + record.RefreshLifetime, token.FamilyExpiresAt.ToUtc()),
            },
            transaction,
            cancellationToken: cancellationToken)).ConfigureAwait(false);

        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return new RotationOutcome(RotationStatus.Rotated, user.ToProfile());
    }

    private static async Task<RotationOutcome> RevokeAsync(
        NpgsqlConnection connection, NpgsqlTransaction transaction, Guid familyId, string reason, DateTimeOffset now,
        RotationStatus status, CancellationToken cancellationToken)
    {
        await connection.ExecuteAsync(new CommandDefinition(
            RevokeFamilySql, new { id = familyId, now, reason }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
        // The revocation is the point of this path: commit it even though the request itself is refused.
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return new RotationOutcome(status, null);
    }

    private static DateTimeOffset Earliest(DateTimeOffset a, DateTimeOffset b) => a <= b ? a : b;

    // Npgsql materialises timestamptz as DateTime (Kind=Utc).
    private sealed class UserRow
    {
        public Guid Id { get; init; }
        public string? DisplayName { get; init; }
        public string Timezone { get; init; } = string.Empty;
        public DateTime CreatedAt { get; init; }
        public DateTime? DeletedAt { get; init; }

        public UserProfile ToProfile() =>
            new(Id, DisplayName, Timezone, new DateTimeOffset(DateTime.SpecifyKind(CreatedAt, DateTimeKind.Utc)));
    }

    private sealed class TokenRow
    {
        public Guid TokenId { get; init; }
        public Guid FamilyId { get; init; }
        public DateTime TokenExpiresAt { get; init; }
        public DateTime? UsedAt { get; init; }
        public Guid UserId { get; init; }
        public Guid? DeviceId { get; init; }
        public DateTime FamilyExpiresAt { get; init; }
        public DateTime? RevokedAt { get; init; }
    }
}

internal static class UtcDateTime
{
    public static DateTimeOffset ToUtc(this DateTime value) => new(DateTime.SpecifyKind(value, DateTimeKind.Utc));
}
