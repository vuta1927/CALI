using System.Text.Json;
using Cali.Infrastructure.Persistence.Migrations;
using Cali.IntegrationTests.Infrastructure;
using Cali.Tests.Shared;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using NpgsqlTypes;

namespace Cali.IntegrationTests;

/// <summary>CON-008: db/008_criteria_config.sql (docs/18 §5; ADR-045, ADR-051, ADR-066, ADR-067).</summary>
[Collection(PostgresCollection.Name)]
public sealed class CriteriaConfigMigrationTests(PostgresFixture postgres)
{
    private static readonly Guid UserId = Guid.Parse("e0000000-0000-4000-8000-000000000001");
    private static readonly Guid PullUpId = Guid.Parse("e1000000-0000-4000-8000-000000000001");
    private static readonly Guid SessionId = Guid.Parse("e2000000-0000-4000-8000-000000000001");
    private static readonly Guid ExecutionId = Guid.Parse("e3000000-0000-4000-8000-000000000001");
    private static readonly Guid LegacySetId = Guid.Parse("e4000000-0000-4000-8000-000000000001");

    [Fact]
    public async Task Upgrade_from_007_keeps_existing_sets_without_criteria()
    {
        var cs = await postgres.CreateDatabaseMigratedUpToAsync("criteria_upgrade", "007_body_measurement.sql", includeDevelopmentScripts: true);
        await SeedLegacyRowsAsync(cs);

        var result = new DatabaseMigrator(NullLogger<DatabaseMigrator>.Instance)
            .Run(cs, RepoPaths.DbDirectory, includeDevelopmentScripts: true);

        result.Successful.ShouldBeTrue(result.Error?.ToString());
        result.AppliedScripts.ShouldContain("008_criteria_config.sql");
        result.AppliedScripts.ShouldNotContain("007_body_measurement.sql");
        (await ScalarAsync<bool>(cs, $"SELECT criteria_version IS NULL AND criteria IS NULL FROM set_results WHERE id = '{LegacySetId}'"))
            .ShouldBeTrue();
    }

    [Fact]
    public async Task Version_1_seed_matches_the_bundled_fixture()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("criteria_seed");

        (await ScalarAsync<long>(cs, "SELECT count(*) FROM criteria_config_versions")).ShouldBe(1);
        var stored = JsonDocument.Parse(await ScalarAsync<string>(cs, "SELECT document::text FROM criteria_config_versions WHERE version = 1")).RootElement;
        var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(RepoPaths.DbDirectory, "..", "fixtures", "criteria_config.json"))).RootElement;

        stored.GetProperty("criteria").EnumerateArray().Select(c => c.GetProperty("id").GetString())
            .ShouldBe(fixture.GetProperty("criteria").EnumerateArray().Select(c => c.GetProperty("id").GetString()));
        JsonElement.DeepEquals(stored.GetProperty("criteria"), fixture.GetProperty("criteria")).ShouldBeTrue();
        JsonElement.DeepEquals(stored.GetProperty("supportedTypes"), fixture.GetProperty("supportedTypes")).ShouldBeTrue();
        // ADR-066: the indicator set version served next to it is the sum of row versions.
        (await ScalarAsync<long>(cs, "SELECT sum(version) FROM indicator_definitions"))
            .ShouldBe(fixture.GetProperty("indicators").GetProperty("version").GetInt64());
    }

    [Theory]
    [InlineData("UPDATE criteria_config_versions SET document = '{\"supportedTypes\":[],\"criteria\":[]}' WHERE version = 1")]
    [InlineData("UPDATE criteria_config_versions SET published_at = now() WHERE version = 1")]
    [InlineData("DELETE FROM criteria_config_versions WHERE version = 1")]
    public async Task Published_versions_are_immutable(string sql)
    {
        // ADR-051: change or roll back = publish a new version.
        var cs = await postgres.CreateMigratedDatabaseAsync("criteria_immutable");

        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, sql));

        error.SqlState.ShouldBe(PostgresErrorCodes.RestrictViolation);
        error.ConstraintName.ShouldBe("ck_criteria_config_versions_immutable");
    }

    [Fact]
    public async Task A_new_version_can_be_published_and_referenced()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("criteria_publish");
        await SeedLegacyRowsAsync(cs);
        await ExecAsync(cs, """
            INSERT INTO criteria_config_versions (version, published_at, document)
            VALUES (2, now(), '{"supportedTypes":["toggle"],"criteria":[]}')
            """);

        await InsertSetAsync(cs, 2, 2, """{"technique":"good"}""");

        (await ScalarAsync<int>(cs, "SELECT criteria_version FROM set_results WHERE set_index = 2")).ShouldBe(2);
    }

    [Theory]
    [InlineData("""{"supportedTypes":"choice","criteria":[]}""")]
    [InlineData("""{"criteria":[]}""")]
    [InlineData("""[]""")]
    public async Task Malformed_config_documents_are_rejected(string document)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("criteria_document_reject");

        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            "INSERT INTO criteria_config_versions (version, published_at, document) VALUES (3, now(), @document)", document));

        error.SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        error.ConstraintName.ShouldBe("ck_criteria_config_versions_document");
    }

    [Fact]
    public async Task Valid_criteria_values_are_stored()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("criteria_accept");
        await SeedLegacyRowsAsync(cs);

        await InsertSetAsync(cs, 2, 1, """{"technique":"good","condition":["same","assist"]}""");

        (await ScalarAsync<string>(cs, "SELECT criteria ->> 'technique' FROM set_results WHERE set_index = 2")).ShouldBe("good");
    }

    [Fact]
    public async Task Worst_case_schema_valid_map_fits_the_size_bound()
    {
        // entity-payloads criteria_values: 20 keys of 32 characters, each with 10 tokens of 32 characters.
        var cs = await postgres.CreateMigratedDatabaseAsync("criteria_worst_case");
        await SeedLegacyRowsAsync(cs);
        var worst = Enumerable.Range(0, 20).ToDictionary(
            i => $"k{i:00}" + new string('x', 29),
            _ => Enumerable.Range(0, 10).Select(j => new string('a', 30) + j.ToString("00", System.Globalization.CultureInfo.InvariantCulture)).ToArray());

        await InsertSetAsync(cs, 2, 1, JsonSerializer.Serialize(worst));

        (await ScalarAsync<int>(cs, "SELECT octet_length(criteria::text) FROM set_results WHERE set_index = 2")).ShouldBeLessThanOrEqualTo(8192);
    }

    [Theory]
    [InlineData(1, null, "ck_set_results_criteria_pair")]
    [InlineData(null, """{"technique":"good"}""", "ck_set_results_criteria_pair")]
    [InlineData(1, """["good"]""", "ck_set_results_criteria")]
    [InlineData(1, """{"rpe":8}""", "ck_set_results_criteria")] // ADR-045: rpe column
    [InlineData(1, """{"pain":true}""", "ck_set_results_criteria")] // pain_reported column
    [InlineData(1, """{"reps":8}""", "ck_set_results_criteria")] // actual_reps column
    public async Task Invalid_criteria_are_rejected_by_named_constraints(int? version, string? criteria, string constraint)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("criteria_reject");
        await SeedLegacyRowsAsync(cs);

        var error = await Should.ThrowAsync<PostgresException>(() => InsertSetAsync(cs, 2, version, criteria));

        error.SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        error.ConstraintName.ShouldBe(constraint);
    }

    [Fact]
    public async Task Oversized_criteria_text_is_rejected()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("criteria_oversize");
        await SeedLegacyRowsAsync(cs);
        var oversized = JsonSerializer.Serialize(Enumerable.Range(0, 300).ToDictionary(i => $"k{i:000}", _ => new string('a', 32)));

        var error = await Should.ThrowAsync<PostgresException>(() => InsertSetAsync(cs, 2, 1, oversized));

        error.SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        error.ConstraintName.ShouldBe("ck_set_results_criteria");
    }

    [Fact]
    public async Task Unknown_criteria_version_is_rejected()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("criteria_fk");
        await SeedLegacyRowsAsync(cs);

        var error = await Should.ThrowAsync<PostgresException>(() => InsertSetAsync(cs, 2, 99, """{"technique":"good"}"""));

        error.SqlState.ShouldBe(PostgresErrorCodes.ForeignKeyViolation);
        error.ConstraintName.ShouldBe("fk_set_results_criteria_version");
    }

    private static Task InsertSetAsync(string cs, int setIndex, int? version, string? criteria) => ExecAsync(cs, $$"""
        INSERT INTO set_results (id, user_id, execution_id, set_index, status, prescribed_snapshot, actual_reps, confirmed_at,
                                 criteria_version, criteria)
        VALUES (gen_random_uuid(), '{{UserId}}', '{{ExecutionId}}', {{setIndex}}, 'completed',
                '{"target":{"kind":"reps","repMin":5,"repMax":8},"setCount":3,"restSeconds":90,"catalogVersion":1}',
                6, now(), {{(version is null ? "NULL" : version.Value.ToString(System.Globalization.CultureInfo.InvariantCulture))}}, @document)
        """, criteria);

    /// <summary>Rows written with the pre-CON-008 schema (no criteria columns referenced).</summary>
    private static Task SeedLegacyRowsAsync(string cs) => ExecAsync(cs, $$"""
        INSERT INTO users (id, timezone) VALUES ('{{UserId}}', 'Asia/Ho_Chi_Minh');
        INSERT INTO exercise_catalog (id, slug, name, exercise_type) VALUES ('{{PullUpId}}', 'sample-pull-up', 'Sample pull-up', 'reps');
        INSERT INTO workout_sessions (id, user_id, local_date, timezone, status, phase, started_at)
        VALUES ('{{SessionId}}', '{{UserId}}', '2026-11-09', 'Asia/Ho_Chi_Minh', 'active', 'exercising', now());
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

    private static async Task ExecAsync(string cs, string sql, string? document = null)
    {
        await using var connection = await OpenAsync(cs);
        await using var command = new NpgsqlCommand(sql, connection);
        if (sql.Contains("@document", StringComparison.Ordinal))
        {
            command.Parameters.Add(new NpgsqlParameter("document", NpgsqlDbType.Jsonb) { Value = (object?)document ?? DBNull.Value });
        }

        await command.ExecuteNonQueryAsync();
    }

    private static async Task<NpgsqlConnection> OpenAsync(string cs)
    {
        var connection = new NpgsqlConnection(cs);
        await connection.OpenAsync();
        return connection;
    }
}
