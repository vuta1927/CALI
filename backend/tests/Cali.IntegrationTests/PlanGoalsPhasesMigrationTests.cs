using Cali.Infrastructure.Persistence.Migrations;
using Cali.IntegrationTests.Infrastructure;
using Cali.Tests.Shared;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

namespace Cali.IntegrationTests;

/// <summary>
/// CON-005: db/005_plan_goals_phases.sql (docs/18 §6.1-§6.5, §8; docs/19 §4; ADR-047, ADR-048,
/// ADR-051; proposed ADR-057, ADR-058, ADR-059).
/// </summary>
[Collection(PostgresCollection.Name)]
public sealed class PlanGoalsPhasesMigrationTests(PostgresFixture postgres)
{
    private const string PinnedGoalLimitState = "CA003";
    private const string GoalUnlockCycleState = "CA004";

    private static readonly Guid UserId = Guid.Parse("e0000000-0000-4000-8000-000000000001");
    private static readonly Guid ExerciseA = Guid.Parse("e5000000-0000-4000-8000-000000000001");
    private static readonly Guid ExerciseB = Guid.Parse("e5000000-0000-4000-8000-000000000002");

    private static Guid PlanId(int n) => Guid.Parse($"e1000000-0000-4000-8000-{n:D12}");

    private static Guid PhaseId(int n) => Guid.Parse($"e2000000-0000-4000-8000-{n:D12}");

    private static Guid GoalId(int n) => Guid.Parse($"e3000000-0000-4000-8000-{n:D12}");

    // ---- migration path ----

    [Fact]
    public async Task Fresh_database_gets_default_indicators_pinned_limit_and_sync_entity_types()
    {
        var cs = await NewDatabaseAsync("goals_fresh");

        (await RowsAsync(cs, "SELECT id, kind, aggregation, array_to_string(measurement_types, ',') FROM indicator_definitions ORDER BY id"))
            .ShouldBe([
                "best_hold_seconds|performance|max|hold",
                "best_set_reps|performance|max|reps",
                "milestone_hold_seconds|milestone|max|hold",
                "milestone_reps|milestone|max|reps",
                "weekly_total_hold_seconds|volume|sum|hold",
                "weekly_total_reps|volume|sum|reps",
            ]);
        (await ScalarAsync<int>(cs, "SELECT cali_setting_int('pinned_goal_limit')")).ShouldBe(3);

        await ExecAsync(cs, $"""
            INSERT INTO sync_change_log (user_id, seq, entity_type, entity_id, operation, server_version) VALUES
              ('{UserId}', 1, 'plan_phase', gen_random_uuid(), 'upsert', 1),
              ('{UserId}', 2, 'plan_goal', gen_random_uuid(), 'upsert', 1);
            """);
        var unknown = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, $"""
            INSERT INTO sync_change_log (user_id, seq, entity_type, entity_id, operation, server_version)
            VALUES ('{UserId}', 3, 'goal', gen_random_uuid(), 'upsert', 1);
            """));
        unknown.ConstraintName.ShouldBe("ck_sync_change_log_entity_type");
        var mutations = await ScalarAsync<string>(cs,
            "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'ck_sync_mutations_entity_type'");
        mutations.ShouldContain("plan_goal");
        mutations.ShouldContain("plan_phase");
        mutations.ShouldContain("plan_activation");
    }

    [Fact]
    public async Task Upgrade_from_004_keeps_existing_plans_and_backfills_nothing()
    {
        var cs = await postgres.CreateDatabaseMigratedUpToAsync("goals_up004", "004_plan_lineage_activation.sql");
        await ExecAsync(cs, $"""
            INSERT INTO users (id, timezone) VALUES ('{UserId}', 'Asia/Ho_Chi_Minh');
            INSERT INTO training_plans (id, user_id, title) VALUES ('{PlanId(1)}', '{UserId}', 'Sample plan');
            """);

        var result = new DatabaseMigrator(NullLogger<DatabaseMigrator>.Instance)
            .Run(cs, RepoPaths.DbDirectory, includeDevelopmentScripts: false);

        result.Successful.ShouldBeTrue(result.Error?.ToString());
        result.AppliedScripts.First().ShouldBe("005_plan_goals_phases.sql");
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM training_plans")).ShouldBe(1);
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM plan_goals")).ShouldBe(0);
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM plan_phases")).ShouldBe(0);

        // A plan created before 005 can take goals afterwards.
        await ExecAsync(cs, GoalSql(1, plan: 1, pinned: true));
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM plan_goals")).ShouldBe(1);
    }

    // ---- pinned limit (ADR-048, CA003) ----

    [Fact]
    public async Task A_fourth_pinned_goal_in_a_lineage_is_rejected_with_pinned_goal_limit()
    {
        var cs = await NewDatabaseAsync("goals_pin");
        await PlanAsync(cs, 1);
        await PlanAsync(cs, 2);
        for (var n = 1; n <= 3; n++)
        {
            await ExecAsync(cs, GoalSql(n, plan: 1, pinned: true));
        }

        var insert = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, GoalSql(4, plan: 1, pinned: true)));
        insert.SqlState.ShouldBe(PinnedGoalLimitState);
        insert.MessageText.ShouldBe("pinned_goal_limit");

        // Unpinned goals are unlimited; pinning one later is checked too.
        await ExecAsync(cs, GoalSql(4, plan: 1));
        var pin = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            $"UPDATE plan_goals SET pinned = true WHERE id = '{GoalId(4)}'"));
        pin.SqlState.ShouldBe(PinnedGoalLimitState);

        // The limit is per lineage.
        await ExecAsync(cs, GoalSql(5, plan: 2, pinned: true));

        // Editing an already pinned goal never trips the limit, and a soft-deleted pin frees its slot.
        await ExecAsync(cs, $"UPDATE plan_goals SET title = 'Renamed' WHERE id = '{GoalId(1)}'");
        await ExecAsync(cs, $"UPDATE plan_goals SET deleted_at = now() WHERE id = '{GoalId(1)}'");
        await ExecAsync(cs, $"UPDATE plan_goals SET pinned = true WHERE id = '{GoalId(4)}'");

        // Restoring the deleted pinned goal would make four.
        var restore = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            $"UPDATE plan_goals SET deleted_at = NULL WHERE id = '{GoalId(1)}'"));
        restore.SqlState.ShouldBe(PinnedGoalLimitState);
    }

    [Fact]
    public async Task Two_devices_pinning_the_third_goal_concurrently_only_one_wins()
    {
        var cs = await NewDatabaseAsync("goals_pin_conc");
        await PlanAsync(cs, 1);
        await ExecAsync(cs, GoalSql(1, plan: 1, pinned: true));
        await ExecAsync(cs, GoalSql(2, plan: 1, pinned: true));

        await using var deviceA = await OpenAsync(cs);
        await using var deviceB = await OpenAsync(cs);
        await using var txA = await deviceA.BeginTransactionAsync();
        await using var txB = await deviceB.BeginTransactionAsync();

        await ExecAsync(deviceA, txA, GoalSql(3, plan: 1, pinned: true));
        var pushB = ExecAsync(deviceB, txB, GoalSql(4, plan: 1, pinned: true));
        await WaitForAdvisoryLockWaiterAsync(cs);
        pushB.IsCompleted.ShouldBeFalse();

        await txA.CommitAsync();
        var error = await Should.ThrowAsync<PostgresException>(() => pushB);
        await txB.RollbackAsync();

        error.SqlState.ShouldBe(PinnedGoalLimitState);
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM plan_goals WHERE pinned")).ShouldBe(3);
    }

    [Fact]
    public async Task Pinned_goal_limit_is_configurable_on_the_server()
    {
        var cs = await NewDatabaseAsync("goals_pin_cfg");
        await PlanAsync(cs, 1);
        await ExecAsync(cs, "UPDATE server_settings SET int_value = 1 WHERE key = 'pinned_goal_limit'");
        await ExecAsync(cs, GoalSql(1, plan: 1, pinned: true));

        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, GoalSql(2, plan: 1, pinned: true)));

        error.SqlState.ShouldBe(PinnedGoalLimitState);
    }

    // ---- unlockAfter (docs/18 §6.3, CA004) ----

    [Fact]
    public async Task An_unlock_after_edit_that_closes_a_cycle_is_rejected_with_goal_unlock_cycle()
    {
        var cs = await NewDatabaseAsync("goals_cycle");
        await PlanAsync(cs, 1);
        await ExecAsync(cs, GoalSql(1, plan: 1));
        await ExecAsync(cs, GoalSql(2, plan: 1, unlockAfter: 1));
        await ExecAsync(cs, GoalSql(3, plan: 1, unlockAfter: 2));

        var cycle = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            $"UPDATE plan_goals SET unlock_after_goal_id = '{GoalId(3)}' WHERE id = '{GoalId(1)}'"));
        cycle.SqlState.ShouldBe(GoalUnlockCycleState);
        cycle.MessageText.ShouldBe("goal_unlock_cycle");

        // A soft-deleted goal still counts, so a later restore cannot close the cycle.
        await ExecAsync(cs, $"UPDATE plan_goals SET deleted_at = now() WHERE id = '{GoalId(2)}'");
        var viaDeleted = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            $"UPDATE plan_goals SET unlock_after_goal_id = '{GoalId(3)}' WHERE id = '{GoalId(1)}'"));
        viaDeleted.SqlState.ShouldBe(GoalUnlockCycleState);

        // A self reference is the shortest cycle; the trigger reports it before ck_plan_goals_unlock_not_self.
        var self = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            $"UPDATE plan_goals SET unlock_after_goal_id = id WHERE id = '{GoalId(1)}'"));
        self.SqlState.ShouldBe(GoalUnlockCycleState);

        // Re-pointing to a goal that is not downstream is fine (a diamond is not a cycle).
        await ExecAsync(cs, GoalSql(4, plan: 1, unlockAfter: 1));
        await ExecAsync(cs, $"UPDATE plan_goals SET unlock_after_goal_id = '{GoalId(4)}' WHERE id = '{GoalId(3)}'");
    }

    [Fact]
    public async Task Unlock_after_and_scope_phase_must_belong_to_the_same_plan()
    {
        var cs = await NewDatabaseAsync("goals_lineage");
        await PlanAsync(cs, 1);
        await PlanAsync(cs, 2);
        await PhaseAsync(cs, 1, plan: 1, order: 0);
        await PhaseAsync(cs, 2, plan: 2, order: 0);
        await ExecAsync(cs, GoalSql(1, plan: 1, scopePhase: 1));
        await ExecAsync(cs, GoalSql(2, plan: 2));

        var unlock = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, GoalSql(3, plan: 1, unlockAfter: 2)));
        unlock.ConstraintName.ShouldBe("ck_plan_goals_unlock_same_lineage");

        var scope = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, GoalSql(3, plan: 1, scopePhase: 2)));
        scope.ConstraintName.ShouldBe("ck_plan_goals_scope_same_lineage");

        // A phase of a newer revision of the same lineage is fine (docs/19 §4: goals follow the lineage).
        await ExecAsync(cs, $"""
            UPDATE training_plans SET status = 'superseded' WHERE id = '{PlanId(1)}';
            INSERT INTO training_plans (id, user_id, title, revision, parent_plan_id)
            VALUES ('{PlanId(3)}', '{UserId}', 'Sample plan 1', 2, '{PlanId(1)}');
            """);
        await PhaseAsync(cs, 3, plan: 3, order: 0);
        await ExecAsync(cs, $"UPDATE plan_goals SET scope_phase_id = '{PhaseId(3)}' WHERE id = '{GoalId(1)}'");

        var missing = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, GoalSql(4, plan: 1, scopePhase: 99)));
        missing.SqlState.ShouldBe(PostgresErrorCodes.ForeignKeyViolation);
        missing.ConstraintName.ShouldBe("fk_plan_goals_scope_phase");
    }

    // ---- references and immutable fields (ADR-047, ADR-057) ----

    [Fact]
    public async Task Goal_must_reference_a_known_lineage_and_indicator()
    {
        var cs = await NewDatabaseAsync("goals_refs");
        await PlanAsync(cs, 1);

        var lineage = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, GoalSql(1, plan: 9)));
        lineage.SqlState.ShouldBe(PostgresErrorCodes.ForeignKeyViolation);
        lineage.ConstraintName.ShouldBe("fk_plan_goals_lineage");

        var indicator = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, GoalSql(1, plan: 1, indicator: "best_pace")));
        indicator.SqlState.ShouldBe(PostgresErrorCodes.ForeignKeyViolation);
        indicator.ConstraintName.ShouldBe("fk_plan_goals_indicator");
    }

    [Theory]
    [InlineData("indicator_id = 'best_set_reps'", "ck_plan_goals_indicator_immutable")]
    [InlineData("exercise_id = 'e5000000-0000-4000-8000-000000000002'", "ck_plan_goals_exercise_immutable")]
    [InlineData("exercise_id = NULL", "ck_plan_goals_exercise_immutable")]
    [InlineData("plan_lineage_id = 'e1000000-0000-4000-8000-000000000002'", "ck_plan_goals_lineage_immutable")]
    public async Task Indicator_exercise_and_lineage_of_a_goal_are_immutable(string assignment, string constraint)
    {
        var cs = await NewDatabaseAsync("goals_immut");
        await ExecAsync(cs, $"""
            INSERT INTO exercise_catalog (id, slug, name, exercise_type) VALUES
              ('{ExerciseA}', 'sample-hold', 'Sample hold', 'static_hold'),
              ('{ExerciseB}', 'sample-reps', 'Sample reps', 'reps');
            """);
        await PlanAsync(cs, 1);
        await PlanAsync(cs, 2);
        await ExecAsync(cs, GoalSql(1, plan: 1, exercise: ExerciseA));

        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            $"UPDATE plan_goals SET {assignment} WHERE id = '{GoalId(1)}'"));

        error.SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        error.ConstraintName.ShouldBe(constraint);
    }

    // ---- field checks ----

    [Theory]
    [InlineData("status = 'achieved'", "ck_plan_goals_achieved_at")]
    [InlineData("achieved_at = now()", "ck_plan_goals_achieved_at")]
    [InlineData("status = 'done'", "ck_plan_goals_status")]
    [InlineData("target_min = 5, target_max = 10", "ck_plan_goals_target")]
    [InlineData("target_value = NULL, target_min = 10, target_max = 5", "ck_plan_goals_target")]
    [InlineData("target_value = NULL", "ck_plan_goals_target")]
    [InlineData("baseline = -1", "ck_plan_goals_values")]
    [InlineData("title = ''", "ck_plan_goals_title")]
    public async Task Goal_fields_are_checked(string assignment, string constraint)
    {
        var cs = await NewDatabaseAsync("goals_fields");
        await PlanAsync(cs, 1);
        await ExecAsync(cs, GoalSql(1, plan: 1));

        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            $"UPDATE plan_goals SET {assignment} WHERE id = '{GoalId(1)}'"));

        error.SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        error.ConstraintName.ShouldBe(constraint);
    }

    [Fact]
    public async Task Achieved_is_stored_only_with_the_users_confirmation_time()
    {
        var cs = await NewDatabaseAsync("goals_achieved");
        await PlanAsync(cs, 1);
        await ExecAsync(cs, GoalSql(1, plan: 1));

        // reached is the device's suggestion; achieved comes with the time of the user's tap.
        await ExecAsync(cs, $"UPDATE plan_goals SET status = 'reached' WHERE id = '{GoalId(1)}'");
        await ExecAsync(cs, $"UPDATE plan_goals SET status = 'achieved', achieved_at = '2026-12-03T19:30:00Z' WHERE id = '{GoalId(1)}'");
        // Archiving keeps the achieved time; a range target is accepted.
        await ExecAsync(cs, $"UPDATE plan_goals SET status = 'archived' WHERE id = '{GoalId(1)}'");
        await ExecAsync(cs, $"UPDATE plan_goals SET target_value = NULL, target_min = 60, target_max = 65 WHERE id = '{GoalId(1)}'");

        (await ScalarAsync<string>(cs, $"SELECT status || '|' || to_char(achieved_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI') FROM plan_goals WHERE id = '{GoalId(1)}'"))
            .ShouldBe("archived|2026-12-03T19:30");
    }

    [Fact]
    public async Task Phase_fields_are_checked_and_a_phase_never_moves_to_another_revision()
    {
        var cs = await NewDatabaseAsync("phases");
        await PlanAsync(cs, 1);
        await PlanAsync(cs, 2);
        await PhaseAsync(cs, 1, plan: 1, order: 0);

        var weeks = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            $"UPDATE plan_phases SET weeks = 0 WHERE id = '{PhaseId(1)}'"));
        weeks.ConstraintName.ShouldBe("ck_plan_phases_weeks");

        var move = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            $"UPDATE plan_phases SET plan_id = '{PlanId(2)}' WHERE id = '{PhaseId(1)}'"));
        move.ConstraintName.ShouldBe("ck_plan_phases_plan_immutable");

        var plan = await Should.ThrowAsync<PostgresException>(() => PhaseAsync(cs, 2, plan: 9, order: 0));
        plan.ConstraintName.ShouldBe("fk_plan_phases_plan");
    }

    // ---- audit (ADR-059) ----

    [Fact]
    public async Task Every_goal_and_phase_change_is_audited_with_the_sync_mutation_id()
    {
        var cs = await NewDatabaseAsync("goals_audit");
        await PlanAsync(cs, 1);
        var mutationId = Guid.Parse("e4000000-0000-4000-8000-000000000001");

        await using (var connection = await OpenAsync(cs))
        await using (var tx = await connection.BeginTransactionAsync())
        {
            await ExecAsync(connection, tx, $"SELECT set_config('cali.mutation_id', '{mutationId}', true)");
            await ExecAsync(connection, tx, $"""
                INSERT INTO plan_phases (id, user_id, plan_id, order_index, name, weeks)
                VALUES ('{PhaseId(1)}', '{UserId}', '{PlanId(1)}', 0, 'Phase one', 4);
                """);
            await ExecAsync(connection, tx, GoalSql(1, plan: 1, scopePhase: 1));
            await tx.CommitAsync();
        }

        await ExecAsync(cs, $"UPDATE plan_goals SET title = 'Renamed', version = version + 1 WHERE id = '{GoalId(1)}'");
        await ExecAsync(cs, $"UPDATE plan_goals SET title = 'Renamed' WHERE id = '{GoalId(1)}'"); // no real change
        await ExecAsync(cs, $"UPDATE plan_goals SET deleted_at = now(), version = version + 1 WHERE id = '{GoalId(1)}'");
        await ExecAsync(cs, $"UPDATE plan_goals SET deleted_at = NULL, version = version + 1 WHERE id = '{GoalId(1)}'");

        (await RowsAsync(cs, """
            SELECT entity_type, operation, entity_version, COALESCE(mutation_id::text, '-'),
                   COALESCE(old_row->>'title', '-'), COALESCE(new_row->>'title', new_row->>'name')
            FROM plan_audit_events ORDER BY id
            """)).ShouldBe([
            $"plan_phase|insert|1|{mutationId}|-|Phase one",
            $"plan_goal|insert|1|{mutationId}|-|Sample goal 1",
            "plan_goal|update|2|-|Sample goal 1|Renamed",
            "plan_goal|delete|3|-|Renamed|Renamed",
            "plan_goal|restore|4|-|Renamed|Renamed",
        ]);
    }

    [Fact]
    public async Task Audit_events_are_append_only_but_leave_with_the_deleted_account()
    {
        var cs = await NewDatabaseAsync("goals_audit_ro");
        await PlanAsync(cs, 1);
        await ExecAsync(cs, GoalSql(1, plan: 1));

        var update = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            "UPDATE plan_audit_events SET operation = 'update'"));
        update.SqlState.ShouldBe(PostgresErrorCodes.RestrictViolation);
        update.ConstraintName.ShouldBe("ck_plan_audit_events_append_only");

        var delete = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, "DELETE FROM plan_audit_events"));
        delete.ConstraintName.ShouldBe("ck_plan_audit_events_append_only");

        await ExecAsync(cs, $"DELETE FROM users WHERE id = '{UserId}'");
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM plan_audit_events")).ShouldBe(0);
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM plan_goals")).ShouldBe(0);
    }

    // ---- indicator_definitions (ADR-051) ----

    [Fact]
    public async Task Indicator_definitions_are_versioned_never_deleted_and_keep_their_meaning()
    {
        var cs = await NewDatabaseAsync("indicators");

        await ExecAsync(cs, "UPDATE indicator_definitions SET label = 'Giữ lâu nhất (giây)' WHERE id = 'best_hold_seconds'");
        await ExecAsync(cs, "UPDATE indicator_definitions SET label = label WHERE id = 'best_hold_seconds'");
        (await ScalarAsync<int>(cs, "SELECT version FROM indicator_definitions WHERE id = 'best_hold_seconds'")).ShouldBe(2);

        var unit = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            "UPDATE indicator_definitions SET unit = 'phút' WHERE id = 'best_hold_seconds'"));
        unit.ConstraintName.ShouldBe("ck_indicator_definitions_immutable");

        var delete = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            "DELETE FROM indicator_definitions WHERE id = 'best_hold_seconds'"));
        delete.SqlState.ShouldBe(PostgresErrorCodes.RestrictViolation);
        delete.ConstraintName.ShouldBe("ck_indicator_definitions_never_deleted");

        var bodyWithExercise = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, """
            INSERT INTO indicator_definitions (id, kind, label, unit, step, aggregation, measurement_types)
            VALUES ('body_weight', 'body', 'Cân nặng', 'kg', 0.1, 'max', ARRAY['reps'])
            """));
        bodyWithExercise.ConstraintName.ShouldBe("ck_indicator_definitions_measurement_types_kind");
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

    private static Task PhaseAsync(string cs, int n, int plan, int order) => ExecAsync(cs, $"""
        INSERT INTO plan_phases (id, user_id, plan_id, order_index, name, weeks)
        VALUES ('{PhaseId(n)}', '{UserId}', '{PlanId(plan)}', {order}, 'Sample phase {n}', 4)
        """);

    private static string GoalSql(
        int n,
        int plan,
        bool pinned = false,
        int? unlockAfter = null,
        int? scopePhase = null,
        string indicator = "best_hold_seconds",
        Guid? exercise = null) => $"""
        INSERT INTO plan_goals (id, user_id, plan_lineage_id, title, indicator_id, exercise_id, target_value,
                                scope_phase_id, unlock_after_goal_id, pinned)
        VALUES ('{GoalId(n)}', '{UserId}', '{PlanId(plan)}', 'Sample goal {n}', '{indicator}',
                {Literal(exercise)}, 10, {Literal(scopePhase is null ? null : PhaseId(scopePhase.Value))},
                {Literal(unlockAfter is null ? null : GoalId(unlockAfter.Value))}, {(pinned ? "true" : "false")})
        """;

    private static string Literal(Guid? id) => id is null ? "NULL" : $"'{id}'";

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
