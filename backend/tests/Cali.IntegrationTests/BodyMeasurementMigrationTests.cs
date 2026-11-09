using Cali.Infrastructure.Persistence.Migrations;
using Cali.IntegrationTests.Infrastructure;
using Cali.Tests.Shared;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

namespace Cali.IntegrationTests;

/// <summary>
/// CON-007: db/007_body_measurement.sql (docs/07, docs/11; ADR-046, ADR-049; ADR-063, ADR-064, ADR-065).
/// </summary>
[Collection(PostgresCollection.Name)]
public sealed class BodyMeasurementMigrationTests(PostgresFixture postgres)
{
    private static readonly Guid UserId = Guid.Parse("f0000000-0000-4000-8000-000000000001");
    private static readonly Guid PlanId = Guid.Parse("f1000000-0000-4000-8000-000000000001");

    [Fact]
    public async Task Upgrade_from_006_keeps_existing_rows_and_adds_an_empty_table()
    {
        var cs = await postgres.CreateDatabaseMigratedUpToAsync("body_upgrade", "006_exercise_discipline_load.sql", includeDevelopmentScripts: true);
        await ExecAsync(cs, $"""
            INSERT INTO users (id, timezone) VALUES ('{UserId}', 'Asia/Ho_Chi_Minh');
            INSERT INTO training_plans (id, user_id, title) VALUES ('{PlanId}', '{UserId}', 'Sample plan');
            """);

        var result = new DatabaseMigrator(NullLogger<DatabaseMigrator>.Instance)
            .Run(cs, RepoPaths.DbDirectory, includeDevelopmentScripts: true);

        result.Successful.ShouldBeTrue(result.Error?.ToString());
        result.AppliedScripts.ShouldContain("007_body_measurement.sql");
        result.AppliedScripts.ShouldNotContain("006_exercise_discipline_load.sql");
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM training_plans")).ShouldBe(1);
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM body_measurements")).ShouldBe(0);
    }

    [Theory]
    [InlineData("20")]
    [InlineData("72.35")]
    [InlineData("72.350")] // value check, not textual scale
    [InlineData("500")]
    public async Task Valid_weights_are_accepted(string kg)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("body_accept");
        await SeedUserAsync(cs);

        await ExecAsync(cs, MeasurementSql("'weight'", kg));

        (await ScalarAsync<decimal>(cs, "SELECT value FROM body_measurements"))
            .ShouldBe(decimal.Parse(kg, System.Globalization.CultureInfo.InvariantCulture));
    }

    [Theory]
    [InlineData("'weight'", "19.99", "ck_body_measurements_value")]
    [InlineData("'weight'", "500.01", "ck_body_measurements_value")]
    [InlineData("'weight'", "72.355", "ck_body_measurements_value")] // ADR-063: more than 2 decimals is rejected, never rounded
    [InlineData("'waist'", "80", "ck_body_measurements_kind")]
    [InlineData("'body_fat'", "20", "ck_body_measurements_kind")]
    public async Task Invalid_measurements_are_rejected_by_named_constraints(string kind, string value, string constraint)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("body_reject");
        await SeedUserAsync(cs);

        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, MeasurementSql(kind, value)));

        error.SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        error.ConstraintName.ShouldBe(constraint);
    }

    [Fact]
    public async Task Several_measurements_per_day_are_allowed_and_rows_go_with_the_user()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("body_many");
        await SeedUserAsync(cs);

        await ExecAsync(cs, MeasurementSql("'weight'", "72.6", "'2026-11-09T06:40:00Z'"));
        await ExecAsync(cs, MeasurementSql("'weight'", "72.1", "'2026-11-09T21:10:00Z'"));
        await ExecAsync(cs, MeasurementSql("'weight'", "72.1", "'2026-11-09T21:10:00Z'"));
        (await ScalarAsync<long>(cs, $"SELECT count(*) FROM body_measurements WHERE user_id = '{UserId}'")).ShouldBe(3);

        // docs/07 §7: users own their data; deleting the account removes it (ON DELETE CASCADE).
        await ExecAsync(cs, $"DELETE FROM users WHERE id = '{UserId}'");
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM body_measurements")).ShouldBe(0);
    }

    [Fact]
    public async Task Body_measurement_is_a_sync_entity_type()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("body_sync");
        await SeedUserAsync(cs);

        await ExecAsync(cs, $"""
            INSERT INTO sync_change_log (user_id, seq, entity_type, entity_id, operation, server_version)
            VALUES ('{UserId}', 1, 'body_measurement', gen_random_uuid(), 'upsert', 1);
            """);
        var mutations = await ScalarAsync<string>(cs,
            "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'ck_sync_mutations_entity_type'");
        mutations.ShouldContain("body_measurement");
        // Earlier entity types are kept.
        mutations.ShouldContain("plan_goal");
        mutations.ShouldContain("training_plan");
        var changes = await ScalarAsync<string>(cs,
            "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'ck_sync_change_log_entity_type'");
        changes.ShouldContain("body_measurement");
        changes.ShouldContain("ai_recommendation");
    }

    [Fact]
    public async Task No_unit_column_and_no_body_indicator_is_seeded()
    {
        // ADR-063: the unit is fixed by the kind (kg, ADR-046). ADR-065: body indicators are deferred.
        var cs = await postgres.CreateMigratedDatabaseAsync("body_shape");

        (await ScalarAsync<long>(cs,
            "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'body_measurements' AND column_name LIKE '%unit%'"))
            .ShouldBe(0);
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM indicator_definitions WHERE kind = 'body'")).ShouldBe(0);
    }

    private static string MeasurementSql(string kind, string value, string measuredAt = "now()") => $"""
        INSERT INTO body_measurements (id, user_id, kind, value, measured_at)
        VALUES (gen_random_uuid(), '{UserId}', {kind}, {value}, {measuredAt});
        """;

    private static Task SeedUserAsync(string cs) =>
        ExecAsync(cs, $"INSERT INTO users (id, timezone) VALUES ('{UserId}', 'Asia/Ho_Chi_Minh');");

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
