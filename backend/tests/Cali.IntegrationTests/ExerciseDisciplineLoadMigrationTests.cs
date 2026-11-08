using Cali.Infrastructure.Persistence.Migrations;
using Cali.IntegrationTests.Infrastructure;
using Cali.Tests.Shared;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

namespace Cali.IntegrationTests;

/// <summary>CON-006: db/006_exercise_discipline_load.sql (docs/18 §4, §8; ADR-046, ADR-060..062).</summary>
[Collection(PostgresCollection.Name)]
public sealed class ExerciseDisciplineLoadMigrationTests(PostgresFixture postgres)
{
    private static readonly Guid UserId = Guid.Parse("d0000000-0000-4000-8000-000000000001");
    private static readonly Guid PullUpId = Guid.Parse("d1000000-0000-4000-8000-000000000001");
    private static readonly Guid RunId = Guid.Parse("d1000000-0000-4000-8000-000000000002");
    private static readonly Guid SquatId = Guid.Parse("d1000000-0000-4000-8000-000000000003");
    private static readonly Guid SessionId = Guid.Parse("d2000000-0000-4000-8000-000000000001");
    private static readonly Guid ExecutionId = Guid.Parse("d3000000-0000-4000-8000-000000000001");
    private static readonly Guid LegacySetId = Guid.Parse("d4000000-0000-4000-8000-000000000001");

    [Fact]
    public async Task Upgrade_from_004_backfills_discipline_and_keeps_existing_rows_valid()
    {
        var cs = await postgres.CreateDatabaseMigratedUpToAsync("load_upgrade", "004_plan_lineage_activation.sql", includeDevelopmentScripts: true);
        await SeedLegacyRowsAsync(cs);

        var result = new DatabaseMigrator(NullLogger<DatabaseMigrator>.Instance)
            .Run(cs, RepoPaths.DbDirectory, includeDevelopmentScripts: true);

        result.Successful.ShouldBeTrue(result.Error?.ToString());
        result.AppliedScripts.ShouldContain("006_exercise_discipline_load.sql");
        result.AppliedScripts.ShouldNotContain("004_plan_lineage_activation.sql");
        result.AppliedScripts.ShouldNotContain("003_running_measurement.sql");

        (await ScalarAsync<string>(cs, $"SELECT discipline FROM exercise_catalog WHERE id = '{PullUpId}'")).ShouldBe("calisthenics");
        (await ScalarAsync<string>(cs, $"SELECT discipline FROM exercise_catalog WHERE id = '{RunId}'")).ShouldBe("running");
        (await ScalarAsync<string>(cs, $"SELECT focus_tags::text FROM exercise_catalog WHERE id = '{PullUpId}'")).ShouldBe("[]");
        // The development seed (db/002) is backfilled too; nothing is left without a discipline.
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM exercise_catalog WHERE discipline IS NULL")).ShouldBe(0);
        (await ScalarAsync<bool>(cs, $"SELECT actual_load_kg IS NULL FROM set_results WHERE id = '{LegacySetId}'")).ShouldBeTrue();
    }

    [Fact]
    public async Task Load_type_is_accepted_and_omitted_discipline_defaults_from_type()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("load_default");
        await ExecAsync(cs, $$"""
            INSERT INTO exercise_catalog (id, slug, name, exercise_type) VALUES
              ('{{SquatId}}', 'sample-back-squat', 'Sample back squat', 'load'),
              ('{{RunId}}', 'sample-easy-run', 'Sample easy run', 'distance'),
              ('{{PullUpId}}', 'sample-pull-up', 'Sample pull-up', 'reps');
            """);

        (await ScalarAsync<string>(cs, $"SELECT discipline FROM exercise_catalog WHERE id = '{SquatId}'")).ShouldBe("gym");
        (await ScalarAsync<string>(cs, $"SELECT discipline FROM exercise_catalog WHERE id = '{RunId}'")).ShouldBe("running");
        (await ScalarAsync<string>(cs, $"SELECT discipline FROM exercise_catalog WHERE id = '{PullUpId}'")).ShouldBe("calisthenics");
    }

    [Fact]
    public async Task Explicit_discipline_is_independent_of_type()
    {
        // ADR-061: a weighted pull-up is calisthenics + load; the trigger never overrides an explicit value.
        var cs = await postgres.CreateMigratedDatabaseAsync("load_explicit");
        await ExecAsync(cs, $$"""
            INSERT INTO exercise_catalog (id, slug, name, exercise_type, discipline, focus_tags)
            VALUES ('{{SquatId}}', 'sample-weighted-pull-up', 'Sample weighted pull-up', 'load', 'calisthenics', '["pull","back"]');
            """);

        (await ScalarAsync<string>(cs, $"SELECT discipline FROM exercise_catalog WHERE id = '{SquatId}'")).ShouldBe("calisthenics");
        (await ScalarAsync<int>(cs, $"SELECT jsonb_array_length(focus_tags) FROM exercise_catalog WHERE id = '{SquatId}'")).ShouldBe(2);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("57.5")]
    [InlineData("57.500")] // value check, not textual scale
    [InlineData("1000")]
    public async Task Valid_load_results_are_accepted(string kg)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("load_accept");
        await SeedLegacyRowsAsync(cs);

        await ExecAsync(cs, LoadSetSql(2, kg));

        (await ScalarAsync<decimal>(cs, "SELECT actual_load_kg FROM set_results WHERE set_index = 2")).ShouldBe(decimal.Parse(kg, System.Globalization.CultureInfo.InvariantCulture));
    }

    [Theory]
    [InlineData("-0.5")]
    [InlineData("1000.01")]
    [InlineData("57.555")] // ADR-062: more than 2 decimals is rejected, never rounded
    public async Task Invalid_load_results_are_rejected_by_named_constraint(string kg)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("load_reject");
        await SeedLegacyRowsAsync(cs);

        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, LoadSetSql(2, kg)));

        error.SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        error.ConstraintName.ShouldBe("ck_set_results_actual_load_kg");
    }

    [Theory]
    [InlineData("'mixed'", "'[]'", "ck_exercise_catalog_discipline")] // plan-level only (PrimaryDiscipline)
    [InlineData("'swim'", "'[]'", "ck_exercise_catalog_discipline")]
    [InlineData("'gym'", "'{}'", "ck_exercise_catalog_focus_tags")]
    public async Task Invalid_catalog_values_are_rejected_by_named_constraints(string discipline, string focusTags, string constraint)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("load_catalog_reject");

        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, $"""
            INSERT INTO exercise_catalog (id, slug, name, exercise_type, discipline, focus_tags)
            VALUES (gen_random_uuid(), 'sample-bad', 'Sample bad', 'load', {discipline}, {focusTags}::jsonb)
            """));

        error.SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        error.ConstraintName.ShouldBe(constraint);
    }

    [Fact]
    public async Task Measurement_type_and_volume_are_not_stored()
    {
        // ADR-060: measurementType is derived from exercise_type; ADR-062: volume is derived from reps x kg.
        var cs = await postgres.CreateMigratedDatabaseAsync("load_derived");

        (await ScalarAsync<long>(cs,
            "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND (column_name LIKE '%measurement%' OR column_name LIKE '%volume%')"))
            .ShouldBe(0);
    }

    private static string LoadSetSql(int setIndex, string kg) => $$"""
        INSERT INTO set_results (id, user_id, execution_id, set_index, status, prescribed_snapshot, actual_reps, actual_load_kg, confirmed_at)
        VALUES (gen_random_uuid(), '{{UserId}}', '{{ExecutionId}}', {{setIndex}}, 'completed',
                '{"target":{"kind":"load","reps":5,"loadKg":60},"setCount":3,"restSeconds":150,"catalogVersion":1}',
                5, {{kg}}, now());
        """;

    /// <summary>Rows written with the pre-CON-006 schema (no discipline / load columns referenced).</summary>
    private static Task SeedLegacyRowsAsync(string cs) => ExecAsync(cs, $$"""
        INSERT INTO users (id, timezone) VALUES ('{{UserId}}', 'Asia/Ho_Chi_Minh');
        INSERT INTO exercise_catalog (id, slug, name, exercise_type) VALUES
          ('{{PullUpId}}', 'sample-pull-up', 'Sample pull-up', 'reps'),
          ('{{RunId}}', 'sample-easy-run', 'Sample easy run', 'distance');
        INSERT INTO workout_sessions (id, user_id, local_date, timezone, status, phase, started_at)
        VALUES ('{{SessionId}}', '{{UserId}}', '2026-11-08', 'Asia/Ho_Chi_Minh', 'active', 'exercising', now());
        INSERT INTO exercise_executions (id, user_id, session_id, exercise_id, order_index, prescribed_snapshot)
        VALUES ('{{ExecutionId}}', '{{UserId}}', '{{SessionId}}', '{{PullUpId}}', 0,
                '{"target":{"kind":"reps","repMin":5,"repMax":8},"setCount":3,"restSeconds":90,"catalogVersion":1}');
        INSERT INTO set_results (id, user_id, execution_id, set_index, status, prescribed_snapshot, actual_reps, confirmed_at)
        VALUES ('{{LegacySetId}}', '{{UserId}}', '{{ExecutionId}}', 1, 'completed',
                '{"target":{"kind":"reps","repMin":5,"repMax":8},"setCount":3,"restSeconds":90,"catalogVersion":1}', 8, now());
        """);

    private static async Task<T> ScalarAsync<T>(string cs, string sql)
    {
        await using var connection = await OpenAsync(cs);
        await using var command = new NpgsqlCommand(sql, connection);
        return (T)(await command.ExecuteScalarAsync())!;
    }

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
