using Cali.Application.Identity;
using Cali.Domain.Identity;
using Dapper;
using Npgsql;

namespace Cali.Infrastructure.Persistence;

public sealed class UserProfileReader(NpgsqlDataSource dataSource) : IUserProfileReader
{
    private const string Sql = """
        SELECT id AS Id, display_name AS DisplayName, timezone AS Timezone, created_at AS CreatedAt
        FROM users
        WHERE id = @id AND deleted_at IS NULL
        """;

    public async Task<UserProfile?> FindByIdAsync(Guid userId, CancellationToken cancellationToken)
    {
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        var row = await connection.QuerySingleOrDefaultAsync<UserRow>(
            new CommandDefinition(Sql, new { id = userId }, cancellationToken: cancellationToken)).ConfigureAwait(false);

        return row is null
            ? null
            : new UserProfile(row.Id, row.DisplayName, row.Timezone, new DateTimeOffset(DateTime.SpecifyKind(row.CreatedAt, DateTimeKind.Utc)));
    }

    // Npgsql materialises timestamptz as DateTime (Kind=Utc).
    private sealed class UserRow
    {
        public Guid Id { get; init; }
        public string? DisplayName { get; init; }
        public string Timezone { get; init; } = string.Empty;
        public DateTime CreatedAt { get; init; }
    }
}
