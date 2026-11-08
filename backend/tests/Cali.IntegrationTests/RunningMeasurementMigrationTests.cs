using Cali.Infrastructure.Persistence.Migrations;
using Cali.IntegrationTests.Infrastructure;
using Cali.Tests.Shared;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

namespace Cali.IntegrationTests;

/// <summary>CON-004: db/003_running_measurement.sql (docs/19 §4.1, ADR-043, ADR-055).</summary>
[Collection(PostgresCollection.Name)]
public sealed class RunningMeasurementMigrationTests(PostgresFixture postgres)
{
    private static readonly Guid UserId = Guid.Parse("e0000000-0000-4000-8000-000000000001");
    private static readonly Guid PullUpId = Guid.Parse("e1000000-0000-4000-8000-000000000001");
    private static readonly Guid RunId = Guid.Parse("e1000000-0000-4000-8000-000000000002");
    private static readonly Guid SessionId = Guid.Parse("e2000000-0000-4000-8000-000000000001");
    private static readonly Guid ExecutionId = Guid.Parse("e3000000-0000-4000-8000-000000000001");
    private static readonly Guid LegacySetId = Guid.Parse("e4000000-0000-4000-8000-000000000001");

    [Fact]
    public async Task Upgrade_from_002_keeps_existing_set_results_valid_with_manual_source()
    {
        var cs = await postgres.CreateDatabaseMigratedUpToAsync("run_upgrade", "002_dev_catalog_seed.sql", includeDevelopmentScripts: true);
        await SeedLegacyRowsAsync(cs);

        var result = new DatabaseMigrator(NullLogger<DatabaseMigrator>.Instance)
            .Run(cs, RepoPaths.DbDirectory, includeDevelopmentScripts: true);

        result.Successful.ShouldBeTrue(result.Error?.ToString());
        result.AppliedScripts.ShouldNotContain("001_initial.sql");
        result.AppliedScripts.ShouldContain("003_running_measurement.sql");
        await using var connection = await OpenAsync(cs);
        await using var command = new NpgsqlCommand(
            "SELECT source, distance_meters IS NULL AND duration_seconds IS NULL, actual_reps FROM set_results WHERE id = @id", connection);
        command.Parameters.AddWithValue("id", LegacySetId);
        await using var reader = await command.ExecuteReaderAsync();
        (await reader.ReadAsync()).ShouldBeTrue();
        reader.GetString(0).ShouldBe("manual");
        reader.GetBoolean(1).ShouldBeTrue();
        reader.GetInt32(2).ShouldBe(8);
    }

    [Fact]
    public async Task Running_exercise_types_and_manual_running_results_are_accepted()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("run_accept");
        await SeedLegacyRowsAsync(cs);
        await ExecAsync(cs, $$"""
            INSERT INTO exercise_catalog (id, slug, name, exercise_type) VALUES
              ('{{RunId}}', 'sample-easy-run', 'Sample easy run', 'distance'),
              ('{{Guid.NewGuid()}}', 'sample-timed-run', 'Sample timed run', 'duration');
            """);

        await ExecAsync(cs, RunningSetSql(2, distance: "5000", duration: "1750", source: "'manual'"));
        // Duration-only segment and the 24h upper bound (IOS-014).
        await ExecAsync(cs, RunningSetSql(3, distance: "NULL", duration: "86400", source: "DEFAULT"));

        await using var connection = await OpenAsync(cs);
        await using var count = new NpgsqlCommand("SELECT count(*) FROM set_results WHERE source = 'manual'", connection);
        ((long)(await count.ExecuteScalarAsync())!).ShouldBe(3);
    }

    [Theory]
    [InlineData("5000", "1750", "'healthkit'", "ck_set_results_source")] // ADR-043: reserved, not accepted yet
    [InlineData("-1", "1750", "'manual'", "ck_set_results_distance_meters")]
    [InlineData("1000001", "1750", "'manual'", "ck_set_results_distance_meters")]
    [InlineData("5000", "86401", "'manual'", "ck_set_results_duration_seconds")] // IOS-014: > 24h rejected
    [InlineData("5000", "-5", "'manual'", "ck_set_results_duration_seconds")]
    public async Task Invalid_running_results_are_rejected_by_named_constraints(string distance, string duration, string source, string constraint)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("run_reject");
        await SeedLegacyRowsAsync(cs);

        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, RunningSetSql(2, distance, duration, source)));

        error.SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        error.ConstraintName.ShouldBe(constraint);
    }

    [Fact]
    public async Task Unknown_exercise_type_is_still_rejected()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("run_type");

        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            "INSERT INTO exercise_catalog (id, slug, name, exercise_type) VALUES (gen_random_uuid(), 'swim', 'Swim', 'swim')"));

        error.ConstraintName.ShouldBe("ck_exercise_catalog_exercise_type");
    }

    [Fact]
    public async Task Pace_is_not_stored()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("run_pace");
        await using var connection = await OpenAsync(cs);
        await using var command = new NpgsqlCommand(
            "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND column_name LIKE '%pace%'", connection);

        ((long)(await command.ExecuteScalarAsync())!).ShouldBe(0);
    }

    private static string RunningSetSql(int setIndex, string distance, string duration, string source) => $$"""
        INSERT INTO set_results (id, user_id, execution_id, set_index, status, prescribed_snapshot,
                                 distance_meters, duration_seconds, source, confirmed_at)
        VALUES (gen_random_uuid(), '{{UserId}}', '{{ExecutionId}}', {{setIndex}}, 'completed',
                '{"target":{"kind":"distance","distanceMeters":5000},"setCount":1,"restSeconds":0,"catalogVersion":1}',
                {{distance}}, {{duration}}, {{source}}, now());
        """;

    /// <summary>Rows written with the pre-CON-004 schema (no running columns referenced).</summary>
    private static Task SeedLegacyRowsAsync(string cs) => ExecAsync(cs, $$"""
        INSERT INTO users (id, timezone) VALUES ('{{UserId}}', 'Asia/Ho_Chi_Minh');
        INSERT INTO exercise_catalog (id, slug, name, exercise_type) VALUES ('{{PullUpId}}', 'sample-pull-up', 'Sample pull-up', 'reps');
        INSERT INTO workout_sessions (id, user_id, local_date, timezone, status, phase, started_at)
        VALUES ('{{SessionId}}', '{{UserId}}', '2026-11-07', 'Asia/Ho_Chi_Minh', 'active', 'exercising', now());
        INSERT INTO exercise_executions (id, user_id, session_id, exercise_id, order_index, prescribed_snapshot)
        VALUES ('{{ExecutionId}}', '{{UserId}}', '{{SessionId}}', '{{PullUpId}}', 0,
                '{"target":{"kind":"reps","repMin":5,"repMax":8},"setCount":3,"restSeconds":90,"catalogVersion":1}');
        INSERT INTO set_results (id, user_id, execution_id, set_index, status, prescribed_snapshot, actual_reps, confirmed_at)
        VALUES ('{{LegacySetId}}', '{{UserId}}', '{{ExecutionId}}', 1, 'completed',
                '{"target":{"kind":"reps","repMin":5,"repMax":8},"setCount":3,"restSeconds":90,"catalogVersion":1}', 8, now());
        """);

    private static async Task ExecAsync(string cs, string sql)
    {
        await using var connection = await OpenAsync(cs);
        await using var command = new NpgsqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync();
    }

    private static async Task<NpgsqlConnection> OpenAsync(string cs)
    {
        var connection = new NpgsqlConnection(cs);
        await connection.OpenAsync();
        return connection;
    }
}
