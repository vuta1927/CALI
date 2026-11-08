using Cali.Infrastructure.Persistence.Migrations;
using Cali.IntegrationTests.Infrastructure;
using Cali.Tests.Shared;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

namespace Cali.IntegrationTests;

/// <summary>
/// CON-003: db/004_plan_lineage_activation.sql (docs/19 §4.4 I1/I2, BR-2, BR-8, BR-10;
/// ADR-036, ADR-040, ADR-041; limit of 3 active plans = docs/19 D1).
/// </summary>
[Collection(PostgresCollection.Name)]
public sealed class PlanLineageActivationMigrationTests(PostgresFixture postgres)
{
    private const string ActivePlanLimitState = "CA001";
    private const string PlanCountLimitState = "CA002";

    private static readonly Guid UserId = Guid.Parse("f0000000-0000-4000-8000-000000000001");
    private static readonly Guid OtherUserId = Guid.Parse("f0000000-0000-4000-8000-000000000002");

    private static Guid PlanId(int n) => Guid.Parse($"f1000000-0000-4000-8000-{n:D12}");

    // ---- lineage ----

    [Fact]
    public async Task Lineage_defaults_to_the_root_plan_and_revisions_inherit_it()
    {
        var cs = await NewDatabaseAsync("lin_default");
        await ExecAsync(cs, $"""
            INSERT INTO training_plans (id, user_id, title) VALUES ('{PlanId(1)}', '{UserId}', 'Sample plan');
            UPDATE training_plans SET status = 'superseded' WHERE id = '{PlanId(1)}';
            INSERT INTO training_plans (id, user_id, title, revision, parent_plan_id)
            VALUES ('{PlanId(2)}', '{UserId}', 'Sample plan', 2, '{PlanId(1)}');
            """);

        (await ScalarAsync<Guid>(cs, $"SELECT lineage_id FROM training_plans WHERE id = '{PlanId(1)}'")).ShouldBe(PlanId(1));
        (await ScalarAsync<Guid>(cs, $"SELECT lineage_id FROM training_plans WHERE id = '{PlanId(2)}'")).ShouldBe(PlanId(1));
        (await ScalarAsync<string>(cs, $"SELECT kind || '/' || primary_discipline || '/' || status FROM training_plans WHERE id = '{PlanId(2)}'"))
            .ShouldBe("weekly/calisthenics/current");
    }

    [Fact]
    public async Task Revision_with_a_foreign_lineage_and_v1_status_values_are_rejected()
    {
        var cs = await NewDatabaseAsync("lin_reject");
        await PlanAsync(cs, 1);
        await PlanAsync(cs, 2);

        var lineage = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, $"""
            INSERT INTO training_plans (id, user_id, title, revision, parent_plan_id, lineage_id, status)
            VALUES ('{PlanId(3)}', '{UserId}', 'Sample', 2, '{PlanId(1)}', '{PlanId(2)}', 'superseded')
            """));
        lineage.ConstraintName.ShouldBe("ck_training_plans_lineage_parent");

        var status = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            $"UPDATE training_plans SET status = 'active' WHERE id = '{PlanId(1)}'"));
        status.ConstraintName.ShouldBe("ck_training_plans_status");

        var twoCurrent = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, $"""
            INSERT INTO training_plans (id, user_id, title, revision, parent_plan_id)
            VALUES ('{PlanId(4)}', '{UserId}', 'Sample', 2, '{PlanId(1)}')
            """));
        twoCurrent.ConstraintName.ShouldBe("ux_training_plans_one_current_per_lineage");
    }

    [Theory]
    [InlineData("kind = 'event'", "ck_training_plans_event_date")]
    [InlineData("end_reason = 'completed'", "ck_training_plans_ended")]
    [InlineData("ended_at = now(), end_reason = 'abandoned'", "ck_training_plans_end_reason")]
    [InlineData("primary_discipline = 'swimming'", "ck_training_plans_primary_discipline")]
    public async Task Plan_lifecycle_fields_are_checked(string assignment, string constraint)
    {
        var cs = await NewDatabaseAsync("plan_fields");
        await PlanAsync(cs, 1);

        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            $"UPDATE training_plans SET {assignment} WHERE id = '{PlanId(1)}'"));

        error.SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        error.ConstraintName.ShouldBe(constraint);
    }

    // ---- I1 ----

    [Fact]
    public async Task I1_overlapping_activations_of_one_plan_are_rejected_but_adjacent_ones_are_accepted()
    {
        var cs = await NewDatabaseAsync("i1");
        await PlanAsync(cs, 1);
        await ActivateAsync(cs, 1, "2026-12-01", "2026-12-10");
        await ActivateAsync(cs, 1, "2026-12-11", null); // starts the day after the previous one ends

        var error = await Should.ThrowAsync<PostgresException>(() => ActivateAsync(cs, 1, "2026-12-10", "2026-12-10"));

        error.SqlState.ShouldBe(PostgresErrorCodes.ExclusionViolation);
        error.ConstraintName.ShouldBe("ex_plan_activations_no_overlap");
    }

    [Fact]
    public async Task I1_a_soft_deleted_activation_does_not_block_a_new_one()
    {
        var cs = await NewDatabaseAsync("i1_deleted");
        await PlanAsync(cs, 1);
        var cancelled = await ActivateAsync(cs, 1, "2026-12-01", null);
        await ExecAsync(cs, $"UPDATE plan_activations SET deleted_at = now() WHERE id = '{cancelled}'");

        await ActivateAsync(cs, 1, "2026-12-05", null);

        (await CountLiveActivationsAsync(cs)).ShouldBe(1);
    }

    [Fact]
    public async Task Activation_must_reference_a_plan_lineage_of_the_same_user()
    {
        var cs = await NewDatabaseAsync("act_fk");
        await ExecAsync(cs, $"INSERT INTO users (id) VALUES ('{OtherUserId}')");
        await ExecAsync(cs, $"INSERT INTO training_plans (id, user_id, title) VALUES ('{PlanId(9)}', '{OtherUserId}', 'Other user plan')");

        var error = await Should.ThrowAsync<PostgresException>(() => ActivateAsync(cs, 9, "2026-12-01", null));

        error.SqlState.ShouldBe(PostgresErrorCodes.ForeignKeyViolation);
        error.ConstraintName.ShouldBe("fk_plan_activations_lineage");
    }

    // ---- I2 ----

    [Fact]
    public async Task I2_a_fourth_plan_on_the_same_day_is_rejected_with_active_plan_limit()
    {
        var cs = await NewDatabaseAsync("i2_seq");
        await PlansWithActivationsAsync(cs, 3, "2026-12-01");
        await PlanAsync(cs, 4);

        var error = await Should.ThrowAsync<PostgresException>(() => ActivateAsync(cs, 4, "2026-12-20", null));

        error.SqlState.ShouldBe(ActivePlanLimitState);
        error.MessageText.ShouldBe("active_plan_limit");
        (await CountLiveActivationsAsync(cs)).ShouldBe(3);
    }

    [Fact]
    public async Task I2_counts_per_day_so_a_plan_may_start_after_another_one_is_paused()
    {
        var cs = await NewDatabaseAsync("i2_days");
        var activations = await PlansWithActivationsAsync(cs, 3, "2026-12-01");
        await PlanAsync(cs, 4);
        // Pause plan 1 (closing never needs the limit check), then plan 4 starts the next day.
        await ExecAsync(cs, $"UPDATE plan_activations SET to_date = '2026-12-14', end_reason = 'paused' WHERE id = '{activations[0]}'");

        await ActivateAsync(cs, 4, "2026-12-15", null);

        // Re-opening plan 1 overlapping plan 4 would make four plans on 2026-12-15.
        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            $"UPDATE plan_activations SET to_date = NULL, end_reason = NULL WHERE id = '{activations[0]}'"));
        error.SqlState.ShouldBe(ActivePlanLimitState);
    }

    [Fact]
    public async Task I2_two_offline_devices_activating_different_plans_concurrently_only_one_wins()
    {
        var cs = await NewDatabaseAsync("i2_conc");
        await PlansWithActivationsAsync(cs, 2, "2026-12-01");
        await PlanAsync(cs, 3);
        await PlanAsync(cs, 4);

        await using var deviceA = await OpenAsync(cs);
        await using var deviceB = await OpenAsync(cs);
        await using var txA = await deviceA.BeginTransactionAsync();
        await using var txB = await deviceB.BeginTransactionAsync();

        await ExecAsync(deviceA, txA, ActivationSql(Guid.NewGuid(), 3, "2026-12-20", null));
        var pushB = ExecAsync(deviceB, txB, ActivationSql(Guid.NewGuid(), 4, "2026-12-20", null));
        await WaitForAdvisoryLockWaiterAsync(cs);
        pushB.IsCompleted.ShouldBeFalse();

        await txA.CommitAsync();
        var error = await Should.ThrowAsync<PostgresException>(() => pushB);
        await txB.RollbackAsync();

        error.SqlState.ShouldBe(ActivePlanLimitState);
        (await CountLiveActivationsAsync(cs)).ShouldBe(3);
    }

    [Fact]
    public async Task I1_two_offline_devices_activating_the_same_plan_concurrently_only_one_wins()
    {
        var cs = await NewDatabaseAsync("i1_conc");
        await PlanAsync(cs, 1);

        await using var deviceA = await OpenAsync(cs);
        await using var deviceB = await OpenAsync(cs);
        await using var txA = await deviceA.BeginTransactionAsync();
        await using var txB = await deviceB.BeginTransactionAsync();

        await ExecAsync(deviceA, txA, ActivationSql(Guid.NewGuid(), 1, "2026-12-20", null));
        var pushB = ExecAsync(deviceB, txB, ActivationSql(Guid.NewGuid(), 1, "2026-12-21", null));
        await WaitForAdvisoryLockWaiterAsync(cs);

        await txA.CommitAsync();
        var error = await Should.ThrowAsync<PostgresException>(() => pushB);
        await txB.RollbackAsync();

        error.SqlState.ShouldBe(PostgresErrorCodes.ExclusionViolation);
        (await CountLiveActivationsAsync(cs)).ShouldBe(1);
    }

    [Fact]
    public async Task I2_soft_deleting_or_ending_a_plan_frees_its_slot()
    {
        var cs = await NewDatabaseAsync("i2_free");
        await PlansWithActivationsAsync(cs, 3, "2026-12-01");
        await PlanAsync(cs, 4);
        await PlanAsync(cs, 5);

        // ADR-040: soft delete. The plan's activation row is still open (client update not yet synced).
        await ExecAsync(cs, $"UPDATE training_plans SET deleted_at = now() WHERE id = '{PlanId(1)}'");
        await ActivateAsync(cs, 4, "2026-12-20", null);

        await ExecAsync(cs, $"UPDATE training_plans SET ended_at = now(), end_reason = 'stopped' WHERE id = '{PlanId(2)}'");
        await ActivateAsync(cs, 5, "2026-12-20", null);

        (await CountLiveActivationsAsync(cs)).ShouldBe(5);
    }

    [Fact]
    public async Task Active_plan_limit_is_configurable_on_the_server()
    {
        var cs = await NewDatabaseAsync("i2_cfg");
        await PlansWithActivationsAsync(cs, 3, "2026-12-01");
        await PlanAsync(cs, 4);
        await PlanAsync(cs, 5);

        await ExecAsync(cs, "UPDATE server_settings SET int_value = 4 WHERE key = 'active_plan_limit'");
        await ActivateAsync(cs, 4, "2026-12-20", null);

        var error = await Should.ThrowAsync<PostgresException>(() => ActivateAsync(cs, 5, "2026-12-20", null));
        error.SqlState.ShouldBe(ActivePlanLimitState);
    }

    // ---- ADR-041 / BR-8 ----

    [Fact]
    public async Task Plan_count_limit_allows_fifty_non_deleted_plans_and_new_revisions_of_them()
    {
        var cs = await NewDatabaseAsync("plan_count");
        await ExecAsync(cs, $"""
            INSERT INTO training_plans (id, user_id, title)
            SELECT gen_random_uuid(), '{UserId}', 'Sample plan ' || n FROM generate_series(1, 49) AS n;
            """);
        await PlanAsync(cs, 50);

        var error = await Should.ThrowAsync<PostgresException>(() => PlanAsync(cs, 51));
        error.SqlState.ShouldBe(PlanCountLimitState);
        error.MessageText.ShouldBe("plan_count_limit");

        // A new revision of an existing plan is not a new plan.
        await ExecAsync(cs, $"""
            UPDATE training_plans SET status = 'superseded' WHERE id = '{PlanId(50)}';
            INSERT INTO training_plans (id, user_id, title, revision, parent_plan_id)
            VALUES ('{PlanId(52)}', '{UserId}', 'Sample plan 50', 2, '{PlanId(50)}');
            """);

        // A soft-deleted plan no longer counts.
        await ExecAsync(cs, $"UPDATE training_plans SET deleted_at = now() WHERE id = '{PlanId(52)}'");
        await PlanAsync(cs, 51);
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM training_plans WHERE status = 'current' AND deleted_at IS NULL")).ShouldBe(50);
    }

    // ---- sync entity types ----

    [Fact]
    public async Task Sync_tables_accept_plan_activation_entity_type()
    {
        var cs = await NewDatabaseAsync("sync_types");
        await ExecAsync(cs, $"""
            INSERT INTO sync_change_log (user_id, seq, entity_type, entity_id, operation, server_version)
            VALUES ('{UserId}', 1, 'plan_activation', gen_random_uuid(), 'upsert', 1);
            """);

        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, $"""
            INSERT INTO sync_change_log (user_id, seq, entity_type, entity_id, operation, server_version)
            VALUES ('{UserId}', 2, 'plan', gen_random_uuid(), 'upsert', 1);
            """));
        error.ConstraintName.ShouldBe("ck_sync_change_log_entity_type");
        (await ScalarAsync<string>(cs,
                "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'ck_sync_mutations_entity_type'"))
            .ShouldContain("plan_activation");
    }

    // ---- BR-10 upgrade path ----

    [Fact]
    public async Task Upgrade_from_003_groups_revisions_into_lineages_and_activates_v1_active_plans()
    {
        var cs = await postgres.CreateDatabaseMigratedUpToAsync("br10", "003_running_measurement.sql", includeDevelopmentScripts: true);
        await ExecAsync(cs, $$"""
            INSERT INTO users (id, timezone) VALUES ('{{UserId}}', 'Asia/Ho_Chi_Minh'), ('{{OtherUserId}}', 'Asia/Ho_Chi_Minh');
            -- Lineage A: AI revision chain 1 -> 2 -> 3 (v1 creates every revision as 'active').
            INSERT INTO training_plans (id, user_id, title, revision, parent_plan_id, status, created_at, updated_at) VALUES
              ('{{PlanId(1)}}', '{{UserId}}', 'Sample A', 1, NULL, 'active', '2026-10-01T02:00:00Z', '2026-10-01T02:00:00Z'),
              ('{{PlanId(2)}}', '{{UserId}}', 'Sample A', 2, '{{PlanId(1)}}', 'active', '2026-10-05T02:00:00Z', '2026-10-05T02:00:00Z'),
              ('{{PlanId(3)}}', '{{UserId}}', 'Sample A', 3, '{{PlanId(2)}}', 'active', '2026-10-09T02:00:00Z', '2026-10-09T02:00:00Z');
            -- B archived, C deleted, D active without sessions (created 2026-10-20 23:30 UTC = 21/10 in Ho Chi Minh).
            INSERT INTO training_plans (id, user_id, title, status, created_at, updated_at, deleted_at) VALUES
              ('{{PlanId(4)}}', '{{UserId}}', 'Sample B', 'archived', '2026-09-01T00:00:00Z', '2026-09-15T00:00:00Z', NULL),
              ('{{PlanId(5)}}', '{{UserId}}', 'Sample C', 'active', '2026-09-01T00:00:00Z', '2026-09-02T00:00:00Z', '2026-09-03T00:00:00Z'),
              ('{{PlanId(6)}}', '{{UserId}}', 'Sample D', 'active', '2026-10-20T23:30:00Z', '2026-10-20T23:30:00Z', NULL);
            -- First workout of lineage A was done on revision 1.
            INSERT INTO planned_workouts (id, user_id, plan_id, weekday) VALUES ('{{PlanId(101)}}', '{{UserId}}', '{{PlanId(1)}}', 1);
            INSERT INTO workout_sessions (id, user_id, planned_workout_id, local_date, timezone, status, phase, started_at, finished_at)
            VALUES ('{{PlanId(201)}}', '{{UserId}}', '{{PlanId(101)}}', '2026-10-03', 'Asia/Ho_Chi_Minh', 'completed', 'completed',
                    '2026-10-03T00:00:00Z', '2026-10-03T01:00:00Z');
            -- Other user: four v1 'active' plans, only the three most recently updated get an activation.
            INSERT INTO training_plans (id, user_id, title, status, created_at, updated_at) VALUES
              ('{{PlanId(11)}}', '{{OtherUserId}}', 'Sample 1', 'active', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z'),
              ('{{PlanId(12)}}', '{{OtherUserId}}', 'Sample 2', 'active', '2026-10-01T00:00:00Z', '2026-10-02T00:00:00Z'),
              ('{{PlanId(13)}}', '{{OtherUserId}}', 'Sample 3', 'active', '2026-10-01T00:00:00Z', '2026-10-03T00:00:00Z'),
              ('{{PlanId(14)}}', '{{OtherUserId}}', 'Sample 4', 'active', '2026-10-01T00:00:00Z', '2026-10-04T00:00:00Z');
            """);

        var result = new DatabaseMigrator(NullLogger<DatabaseMigrator>.Instance)
            .Run(cs, RepoPaths.DbDirectory, includeDevelopmentScripts: true);

        result.Successful.ShouldBeTrue(result.Error?.ToString());
        // 004 runs first; later numbered migrations (005+) follow on the same upgrade path.
        result.AppliedScripts.First().ShouldBe("004_plan_lineage_activation.sql");

        var plans = await RowsAsync(cs, $"""
            SELECT id::text, lineage_id::text, status, kind, primary_discipline, archived_at IS NOT NULL
            FROM training_plans WHERE user_id = '{UserId}' ORDER BY id
            """);
        plans.ShouldBe([
            $"{PlanId(1)}|{PlanId(1)}|superseded|weekly|calisthenics|False",
            $"{PlanId(2)}|{PlanId(1)}|superseded|weekly|calisthenics|False",
            $"{PlanId(3)}|{PlanId(1)}|current|weekly|calisthenics|False",
            $"{PlanId(4)}|{PlanId(4)}|current|weekly|calisthenics|True",
            $"{PlanId(5)}|{PlanId(5)}|current|weekly|calisthenics|False",
            $"{PlanId(6)}|{PlanId(6)}|current|weekly|calisthenics|False",
        ]);

        var activations = await RowsAsync(cs, """
            SELECT plan_lineage_id::text, from_date::text, COALESCE(to_date::text, '-'), timezone
            FROM plan_activations ORDER BY plan_lineage_id
            """);
        activations.ShouldBe([
            $"{PlanId(1)}|2026-10-03|-|Asia/Ho_Chi_Minh", // first session date
            $"{PlanId(6)}|2026-10-21|-|Asia/Ho_Chi_Minh", // creation date in the user's time zone
            $"{PlanId(12)}|2026-10-01|-|Asia/Ho_Chi_Minh",
            $"{PlanId(13)}|2026-10-01|-|Asia/Ho_Chi_Minh",
            $"{PlanId(14)}|2026-10-01|-|Asia/Ho_Chi_Minh",
        ]);
    }

    // ---- helpers ----

    private async Task<string> NewDatabaseAsync(string prefix)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync(prefix);
        await ExecAsync(cs, $"INSERT INTO users (id, timezone) VALUES ('{UserId}', 'Asia/Ho_Chi_Minh')");
        return cs;
    }

    private static Task PlanAsync(string cs, int n) => ExecAsync(cs,
        $"INSERT INTO training_plans (id, user_id, title) VALUES ('{PlanId(n)}', '{UserId}', 'Sample plan {n}')");

    private static async Task<List<Guid>> PlansWithActivationsAsync(string cs, int count, string fromDate)
    {
        var ids = new List<Guid>();
        for (var n = 1; n <= count; n++)
        {
            await PlanAsync(cs, n);
            ids.Add(await ActivateAsync(cs, n, fromDate, null));
        }

        return ids;
    }

    private static async Task<Guid> ActivateAsync(string cs, int plan, string fromDate, string? toDate)
    {
        var id = Guid.NewGuid();
        await ExecAsync(cs, ActivationSql(id, plan, fromDate, toDate));
        return id;
    }

    private static string ActivationSql(Guid id, int plan, string fromDate, string? toDate) => $"""
        INSERT INTO plan_activations (id, user_id, plan_lineage_id, from_date, to_date, timezone)
        VALUES ('{id}', '{UserId}', '{PlanId(plan)}', '{fromDate}', {(toDate is null ? "NULL" : $"'{toDate}'")}, 'Asia/Ho_Chi_Minh')
        """;

    private static Task<long> CountLiveActivationsAsync(string cs) =>
        ScalarAsync<long>(cs, "SELECT count(*) FROM plan_activations WHERE deleted_at IS NULL");

    private static async Task WaitForAdvisoryLockWaiterAsync(string cs)
    {
        for (var attempt = 0; attempt < 100; attempt++)
        {
            if (await ScalarAsync<long>(cs, "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted") > 0)
            {
                return;
            }

            await Task.Delay(100);
        }

        throw new TimeoutException("The second device never waited on the per-user advisory lock.");
    }

    private static async Task<List<string>> RowsAsync(string cs, string sql)
    {
        await using var connection = await OpenAsync(cs);
        await using var command = new NpgsqlCommand(sql, connection);
        await using var reader = await command.ExecuteReaderAsync();
        var rows = new List<string>();
        while (await reader.ReadAsync())
        {
            rows.Add(string.Join('|', Enumerable.Range(0, reader.FieldCount).Select(i => Convert.ToString(reader.GetValue(i), System.Globalization.CultureInfo.InvariantCulture))));
        }

        return rows;
    }

    private static async Task<T> ScalarAsync<T>(string cs, string sql)
    {
        await using var connection = await OpenAsync(cs);
        await using var command = new NpgsqlCommand(sql, connection);
        return (T)(await command.ExecuteScalarAsync())!;
    }

    private static async Task ExecAsync(string cs, string sql)
    {
        await using var connection = await OpenAsync(cs);
        await ExecAsync(connection, null, sql);
    }

    private static async Task ExecAsync(NpgsqlConnection connection, NpgsqlTransaction? transaction, string sql)
    {
        await using var command = new NpgsqlCommand(sql, connection, transaction);
        await command.ExecuteNonQueryAsync();
    }

    private static async Task<NpgsqlConnection> OpenAsync(string cs)
    {
        var connection = new NpgsqlConnection(cs);
        await connection.OpenAsync();
        return connection;
    }
}
