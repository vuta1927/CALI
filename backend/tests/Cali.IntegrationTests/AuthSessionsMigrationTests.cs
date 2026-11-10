using Cali.Infrastructure.Persistence.Migrations;
using Cali.IntegrationTests.Infrastructure;
using Cali.Tests.Shared;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

namespace Cali.IntegrationTests;

/// <summary>BE-005: db/010_auth_sessions.sql (ADR-071).</summary>
[Collection(PostgresCollection.Name)]
public sealed class AuthSessionsMigrationTests(PostgresFixture postgres)
{
    private static readonly Guid UserId = Guid.Parse("a0000000-0000-4000-8000-000000000001");
    private static readonly Guid FamilyId = Guid.Parse("a1000000-0000-4000-8000-000000000001");

    private static string Hash(char c) => $"decode('{new string(c, 64)}', 'hex')";

    [Fact]
    public async Task Upgrade_from_009_adds_the_auth_tables_and_keeps_existing_users()
    {
        var cs = await postgres.CreateDatabaseMigratedUpToAsync("auth_upgrade", "009_http_idempotency.sql", includeDevelopmentScripts: true);
        await ExecAsync(cs, $"INSERT INTO users (id, apple_subject) VALUES ('{UserId}', 'existing-subject')");

        var result = new DatabaseMigrator(NullLogger<DatabaseMigrator>.Instance)
            .Run(cs, RepoPaths.DbDirectory, includeDevelopmentScripts: true);

        result.Successful.ShouldBeTrue(result.Error?.ToString());
        result.AppliedScripts.ShouldContain("010_auth_sessions.sql");
        result.AppliedScripts.ShouldNotContain("009_http_idempotency.sql");
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM users WHERE apple_subject = 'existing-subject'")).ShouldBe(1);
        (await ScalarAsync<long>(cs, """
            SELECT count(*) FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name IN ('auth_apple_nonces', 'auth_refresh_families', 'auth_refresh_tokens')
            """)).ShouldBe(3);
    }

    [Fact]
    public async Task A_nonce_row_must_hold_a_sha256_and_is_unique()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("auth_nonce");

        await ExecAsync(cs, $"INSERT INTO auth_apple_nonces (nonce_sha256, expires_at) VALUES ({Hash('a')}, now())");
        (await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, $"INSERT INTO auth_apple_nonces (nonce_sha256, expires_at) VALUES ({Hash('a')}, now())")))
            .SqlState.ShouldBe(PostgresErrorCodes.UniqueViolation);
        (await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, "INSERT INTO auth_apple_nonces (nonce_sha256, expires_at) VALUES ('\\x1234', now())")))
            .SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
    }

    [Fact]
    public async Task A_family_needs_a_user_a_lifetime_and_a_consistent_revocation()
    {
        var cs = await SeedUserAsync("auth_family");

        await ExecAsync(cs, Family());
        (await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, Family(Guid.NewGuid(), userId: Guid.NewGuid()))))
            .SqlState.ShouldBe(PostgresErrorCodes.ForeignKeyViolation);
        (await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, Family(Guid.NewGuid(), expires: "now() - interval '1 day'"))))
            .SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        (await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, $"UPDATE auth_refresh_families SET revoked_at = now() WHERE id = '{FamilyId}'")))
            .SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        (await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, $"UPDATE auth_refresh_families SET revoked_at = now(), revoked_reason = 'because' WHERE id = '{FamilyId}'")))
            .SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        await ExecAsync(cs, $"UPDATE auth_refresh_families SET revoked_at = now(), revoked_reason = 'reuse' WHERE id = '{FamilyId}'");
    }

    [Fact]
    public async Task A_family_holds_at_most_one_unused_token_and_tokens_are_unique()
    {
        var cs = await SeedUserAsync("auth_tokens");
        await ExecAsync(cs, Family());

        await ExecAsync(cs, Token('a'));
        // A second live token in the same family is the broken chain the partial index exists to refuse.
        (await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, Token('b'))))
            .SqlState.ShouldBe(PostgresErrorCodes.UniqueViolation);

        // Rotation: the head is spent, then the next one may be added.
        await ExecAsync(cs, "UPDATE auth_refresh_tokens SET used_at = now()");
        await ExecAsync(cs, Token('b'));
        (await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, Token('b'))))
            .SqlState.ShouldBe(PostgresErrorCodes.UniqueViolation);
        (await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, $"INSERT INTO auth_refresh_tokens (family_id, token_sha256, expires_at) VALUES ('{FamilyId}', '\\x12', now() + interval '1 day')")))
            .SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
    }

    [Fact]
    public async Task Deleting_a_user_deletes_the_sessions()
    {
        var cs = await SeedUserAsync("auth_cascade");
        await ExecAsync(cs, Family());
        await ExecAsync(cs, Token('a'));

        await ExecAsync(cs, $"DELETE FROM users WHERE id = '{UserId}'");

        (await ScalarAsync<long>(cs, "SELECT count(*) FROM auth_refresh_families")).ShouldBe(0);
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM auth_refresh_tokens")).ShouldBe(0);
    }

    private async Task<string> SeedUserAsync(string prefix)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync(prefix);
        await ExecAsync(cs, $"INSERT INTO users (id) VALUES ('{UserId}')");
        return cs;
    }

    private static string Family(Guid? id = null, Guid? userId = null, string expires = "now() + interval '180 days'") =>
        $"INSERT INTO auth_refresh_families (id, user_id, expires_at) VALUES ('{id ?? FamilyId}', '{userId ?? UserId}', {expires})";

    private static string Token(char hash) =>
        $"INSERT INTO auth_refresh_tokens (family_id, token_sha256, expires_at) VALUES ('{FamilyId}', {Hash(hash)}, now() + interval '60 days')";

    private static async Task ExecAsync(string connectionString, string sql)
    {
        await using var dataSource = NpgsqlDataSource.Create(connectionString);
        await using var command = dataSource.CreateCommand(sql);
        await command.ExecuteNonQueryAsync();
    }

    private static async Task<T> ScalarAsync<T>(string connectionString, string sql)
    {
        await using var dataSource = NpgsqlDataSource.Create(connectionString);
        await using var command = dataSource.CreateCommand(sql);
        return (T)(await command.ExecuteScalarAsync())!;
    }
}
