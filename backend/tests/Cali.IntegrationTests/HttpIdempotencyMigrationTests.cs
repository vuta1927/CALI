using Cali.Infrastructure.Persistence.Migrations;
using Cali.IntegrationTests.Infrastructure;
using Cali.Tests.Shared;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

namespace Cali.IntegrationTests;

/// <summary>BE-002: db/009_http_idempotency.sql (ADR-068).</summary>
[Collection(PostgresCollection.Name)]
public sealed class HttpIdempotencyMigrationTests(PostgresFixture postgres)
{
    private static readonly Guid UserId = Guid.Parse("f0000000-0000-4000-8000-000000000001");
    private static readonly Guid Key = Guid.Parse("f1000000-0000-4000-8000-000000000001");
    private static readonly string Sha = new('a', 64);

    [Fact]
    public async Task Upgrade_from_008_adds_the_table_and_the_plan_page_index()
    {
        var cs = await postgres.CreateDatabaseMigratedUpToAsync("idem_upgrade", "008_criteria_config.sql", includeDevelopmentScripts: true);
        await ExecAsync(cs, $"INSERT INTO users (id) VALUES ('{UserId}')");
        await ExecAsync(cs, $"INSERT INTO training_plans (id, user_id, title) VALUES (gen_random_uuid(), '{UserId}', 'Existing')");

        var result = new DatabaseMigrator(NullLogger<DatabaseMigrator>.Instance)
            .Run(cs, RepoPaths.DbDirectory, includeDevelopmentScripts: true);

        result.Successful.ShouldBeTrue(result.Error?.ToString());
        result.AppliedScripts.ShouldBe(["009_http_idempotency.sql"]);
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM training_plans")).ShouldBe(1);
        (await ScalarAsync<string>(cs, "SELECT indexdef FROM pg_indexes WHERE indexname = 'idx_training_plans_user_created'"))
            .ShouldContain("(user_id, created_at, id) WHERE (deleted_at IS NULL)");
    }

    [Fact]
    public async Task A_valid_row_is_accepted_and_keys_are_unique_per_user()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("idem_valid");
        await ExecAsync(cs, $"INSERT INTO users (id) VALUES ('{UserId}'), ('{Guid.NewGuid()}')");

        await ExecAsync(cs, Insert());
        var duplicate = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, Insert()));
        duplicate.SqlState.ShouldBe(PostgresErrorCodes.UniqueViolation);

        // The same key for another user is a different row.
        await ExecAsync(cs, $"""
            INSERT INTO http_idempotency_keys (user_id, idempotency_key, operation, request_sha256, status_code, response_body)
            SELECT id, '{Key}', 'createPlan', '{Sha}', 201, jsonb_build_object() FROM users WHERE id <> '{UserId}'
            """);
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM http_idempotency_keys")).ShouldBe(2);

        // Deleting the user removes its stored responses.
        await ExecAsync(cs, $"DELETE FROM users WHERE id = '{UserId}'");
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM http_idempotency_keys")).ShouldBe(1);
    }

    [Theory]
    [InlineData("operation", "'deletePlan'", "ck_http_idempotency_keys_operation")]
    [InlineData("request_sha256", "'ABCDEF0000000000000000000000000000000000000000000000000000000000'", "ck_http_idempotency_keys_request_sha256")]
    [InlineData("status_code", "409", "ck_http_idempotency_keys_status_code")]
    [InlineData("response_body", "'[]'", "ck_http_idempotency_keys_response_body")]
    public async Task Constraints_reject_invalid_rows(string column, string value, string constraint)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("idem_check");
        await ExecAsync(cs, $"INSERT INTO users (id) VALUES ('{UserId}')");

        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, Insert(column, value)));

        error.SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        error.ConstraintName.ShouldBe(constraint);
    }

    private static string Insert(string? column = null, string? value = null)
    {
        var values = new Dictionary<string, string>
        {
            ["user_id"] = $"'{UserId}'",
            ["idempotency_key"] = $"'{Key}'",
            ["operation"] = "'createPlan'",
            ["request_sha256"] = $"'{Sha}'",
            ["status_code"] = "201",
            ["response_body"] = "'{\"id\":\"x\"}'",
        };
        if (column is not null)
        {
            values[column] = value!;
        }

        return $"INSERT INTO http_idempotency_keys ({string.Join(", ", values.Keys)}) VALUES ({string.Join(", ", values.Values)})";
    }

    private static async Task<T> ScalarAsync<T>(string cs, string sql)
    {
        await using var connection = new NpgsqlConnection(cs);
        await connection.OpenAsync();
        await using var command = new NpgsqlCommand(sql, connection);
        return (T)(await command.ExecuteScalarAsync())!;
    }

    private static async Task ExecAsync(string cs, string sql)
    {
        await using var connection = new NpgsqlConnection(cs);
        await connection.OpenAsync();
        await using var command = new NpgsqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync();
    }
}
