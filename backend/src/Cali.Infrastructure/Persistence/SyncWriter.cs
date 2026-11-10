using System.Data;
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using Cali.Application.Sync;
using Dapper;
using Npgsql;

namespace Cali.Infrastructure.Persistence;

/// <summary>
/// Applies a sync push batch (BE-003, ADR-069). One READ COMMITTED transaction per request:
/// lock the user (FOR SHARE), register the device, lock <c>user_sync_state</c> (FOR UPDATE, which
/// serializes this user's writers so <c>seq</c> stays gap-free), then apply every mutation inside its
/// own savepoint in request order. A failing mutation rolls back only its savepoint and gets a receipt;
/// the batch still commits. Stored receipts replay as <c>duplicate</c> (docs/08).
/// </summary>
public sealed class SyncWriter(NpgsqlDataSource dataSource) : ISyncWriter
{
    private const string Savepoint = "m";
    private const string ActivePlanLimitSqlState = "CA001";
    private const string PlanCountLimitSqlState = "CA002";
    private const string PinnedGoalLimitSqlState = "CA003";
    private const string GoalUnlockCycleSqlState = "CA004";
    private const string ExclusionViolationSqlState = "23P01";

    private const string LockUserSql = "SELECT 1 FROM users WHERE id = @userId AND deleted_at IS NULL FOR SHARE";

    // devices has two unique indexes (id) and (id, user_id). ON CONFLICT with a target arbitrates only one
    // of them, so two first pushes from a new device would race into 23505 on the other; an untargeted
    // DO NOTHING covers both. The owner-scoped UPDATE then touches the row; no row back = the device id
    // is registered to another user (ADR-033).
    private const string InsertDeviceSql = "INSERT INTO devices (id, user_id) VALUES (@deviceId, @userId) ON CONFLICT DO NOTHING";

    private const string TouchDeviceSql = """
        UPDATE devices SET last_seen_at = clock_timestamp()
        WHERE id = @deviceId AND user_id = @userId
        RETURNING user_id
        """;

    private const string EnsureSyncStateSql = "INSERT INTO user_sync_state (user_id) VALUES (@userId) ON CONFLICT (user_id) DO NOTHING";

    private const string LockSyncStateSql = "SELECT last_seq FROM user_sync_state WHERE user_id = @userId FOR UPDATE";

    private const string AdvanceSeqSql = "UPDATE user_sync_state SET last_seq = last_seq + 1 WHERE user_id = @userId RETURNING last_seq";

    // Audit triggers (db/005 plan_audit_events) read this transaction-local setting.
    private const string SetMutationIdSql = "SELECT set_config('cali.mutation_id', @mutationId, true)";

    private const string FindMutationSql = """
        SELECT payload_sha256 AS PayloadSha256, receipt::text AS Receipt
        FROM sync_mutations WHERE user_id = @userId AND mutation_id = @mutationId
        """;

    private const string InsertMutationSql = """
        INSERT INTO sync_mutations (user_id, mutation_id, device_id, entity_type, entity_id, action, base_version,
                                    status, receipt, payload_sha256, created_at)
        VALUES (@userId, @mutationId, @deviceId, @entityType, @entityId, @action, @baseVersion,
                @status, CAST(@receipt AS jsonb), @payloadSha256, clock_timestamp())
        """;

    private const string InsertChangeSql = """
        INSERT INTO sync_change_log (user_id, seq, entity_type, entity_id, operation, server_version, payload, changed_at)
        VALUES (@userId, @seq, @entityType, @entityId, @operation, @serverVersion, CAST(@payload AS jsonb), clock_timestamp())
        """;

    private const string LatestChangeSql = """
        SELECT payload::text FROM sync_change_log
        WHERE user_id = @userId AND entity_type = @entityType AND entity_id = @entityId
        ORDER BY seq DESC LIMIT 1
        """;

    private const string LineageExistsSql = "SELECT 1 FROM training_plans WHERE user_id = @userId AND lineage_id = @lineageId LIMIT 1";

    public async Task<SyncWriteResult> PushAsync(Guid userId, Guid deviceId, IReadOnlyList<PreparedMutation> mutations, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(mutations);

        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        await using var transaction = await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, cancellationToken).ConfigureAwait(false);
        var db = new Db(connection, transaction, cancellationToken);

        if (await db.ScalarAsync<int?>(LockUserSql, new { userId }).ConfigureAwait(false) is null)
        {
            return new SyncWriteResult(SyncWriteStatus.UserNotFound, []);
        }

        await db.ExecuteAsync(InsertDeviceSql, new { deviceId, userId }).ConfigureAwait(false);
        if (await db.ScalarAsync<Guid?>(TouchDeviceSql, new { deviceId, userId }).ConfigureAwait(false) is null)
        {
            return new SyncWriteResult(SyncWriteStatus.DeviceOwnerMismatch, []);
        }

        await db.ExecuteAsync(EnsureSyncStateSql, new { userId }).ConfigureAwait(false);
        await db.ScalarAsync<long>(LockSyncStateSql, new { userId }).ConfigureAwait(false);

        var receipts = new List<SyncReceipt>(mutations.Count);
        foreach (var prepared in mutations)
        {
            receipts.Add(await ApplyAsync(db, transaction, userId, deviceId, prepared, cancellationToken).ConfigureAwait(false));
        }

        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return new SyncWriteResult(SyncWriteStatus.Written, receipts);
    }

    private static async Task<SyncReceipt> ApplyAsync(
        Db db, NpgsqlTransaction transaction, Guid userId, Guid deviceId, PreparedMutation prepared, CancellationToken cancellationToken)
    {
        var mutation = prepared.Mutation;
        await db.ScalarAsync<string>(SetMutationIdSql, new { mutationId = mutation.MutationId.ToString("D") }).ConfigureAwait(false);
        await transaction.SaveAsync(Savepoint, cancellationToken).ConfigureAwait(false);

        var stored = await db.SingleOrDefaultAsync<StoredMutation>(FindMutationSql, new { userId, mutationId = mutation.MutationId }).ConfigureAwait(false);
        if (stored is not null)
        {
            await transaction.ReleaseAsync(Savepoint, cancellationToken).ConfigureAwait(false);
            return string.Equals(stored.PayloadSha256, prepared.Fingerprint, StringComparison.Ordinal)
                ? SyncReceipt.FromJson(stored.Receipt) with { Status = ReceiptStatuses.Duplicate }
                : SyncReceipt.Rejected(mutation.MutationId, ReceiptCodes.MutationIdReused,
                    "This mutationId was already used for a different mutation.", "mutationId");
        }

        SyncReceipt receipt;
        try
        {
            receipt = prepared.Rejection
                ?? await CheckReferencesAsync(db, userId, prepared).ConfigureAwait(false)
                ?? await WriteAsync(db, userId, prepared).ConfigureAwait(false);
        }
        catch (PostgresException e) when (Map(mutation.MutationId, e) is { } mapped)
        {
            receipt = mapped;
        }

        if (receipt.Status != ReceiptStatuses.Applied)
        {
            // Nothing of a non-applied mutation is kept except its stored receipt.
            await transaction.RollbackAsync(Savepoint, cancellationToken).ConfigureAwait(false);
        }

        if (receipt.IsStored)
        {
            await db.ExecuteAsync(InsertMutationSql, new
            {
                userId,
                mutationId = mutation.MutationId,
                deviceId,
                entityType = mutation.EntityType,
                entityId = mutation.EntityId,
                action = mutation.Action,
                baseVersion = mutation.BaseVersion,
                status = receipt.Status,
                receipt = receipt.ToJson().ToJsonString(),
                payloadSha256 = prepared.Fingerprint,
            }).ConfigureAwait(false);
        }

        await transaction.ReleaseAsync(Savepoint, cancellationToken).ConfigureAwait(false);
        return receipt;
    }

    private static async Task<SyncReceipt?> CheckReferencesAsync(Db db, Guid userId, PreparedMutation prepared)
    {
        var mutationId = prepared.Mutation.MutationId;
        foreach (var reference in prepared.References)
        {
            switch (reference)
            {
                case ParentReference parent:
                    var owner = await db.ScalarAsync<Guid?>(
                        string.Create(CultureInfo.InvariantCulture, $"SELECT user_id FROM {parent.Table} WHERE id = @id"), new { id = parent.Id })
                        .ConfigureAwait(false);
                    if (owner is null)
                    {
                        return SyncReceipt.DependencyMissing(mutationId, parent.Field, "The referenced row does not exist on the server yet.");
                    }

                    if (owner != userId)
                    {
                        return SyncReceipt.Rejected(mutationId, ReceiptCodes.CrossUserReference, "The referenced row belongs to another user.", parent.Field);
                    }

                    break;
                case LineageReference lineage:
                    if (await db.ScalarAsync<int?>(LineageExistsSql, new { userId, lineageId = lineage.LineageId }).ConfigureAwait(false) is null)
                    {
                        return SyncReceipt.DependencyMissing(mutationId, lineage.Field, "The referenced plan lineage does not exist on the server yet.");
                    }

                    break;
            }
        }

        return null;
    }

    private static async Task<SyncReceipt> WriteAsync(Db db, Guid userId, PreparedMutation prepared)
    {
        var mutation = prepared.Mutation;
        var table = prepared.Table!;
        var row = await db.SingleOrDefaultAsync<CurrentRow>(
            string.Create(CultureInfo.InvariantCulture,
                $"SELECT user_id AS UserId, version AS Version, deleted_at IS NOT NULL AS Deleted FROM {table} WHERE id = @id FOR UPDATE"),
            new { id = mutation.EntityId }).ConfigureAwait(false);

        if (row is not null && row.UserId != userId)
        {
            return SyncReceipt.Rejected(mutation.MutationId, ReceiptCodes.CrossUserReference, "This entity id belongs to another user.", "entityId");
        }

        var expectsNew = mutation.BaseVersion == 0;
        var conflict = row is null
            ? !expectsNew || prepared.IsDelete
            : row.Deleted || row.Version != mutation.BaseVersion;
        if (conflict)
        {
            var latest = await db.ScalarAsync<string?>(LatestChangeSql,
                new { userId, entityType = mutation.EntityType, entityId = mutation.EntityId }).ConfigureAwait(false);
            return SyncReceipt.VersionConflict(mutation.MutationId, row?.Version, latest);
        }

        long version;
        string operation;
        string change;
        if (prepared.IsDelete)
        {
            var deleted = await db.SingleAsync<DeletedRow>(
                string.Create(CultureInfo.InvariantCulture,
                    $"UPDATE {table} SET deleted_at = clock_timestamp(), version = version + 1, updated_at = clock_timestamp() WHERE id = @id RETURNING version AS Version, deleted_at AS DeletedAt"),
                new { id = mutation.EntityId }).ConfigureAwait(false);
            version = deleted.Version;
            operation = "delete";
            change = new JsonObject
            {
                ["id"] = mutation.EntityId.ToString("D"),
                ["deletedAt"] = DateTime.SpecifyKind(deleted.DeletedAt, DateTimeKind.Utc).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture),
            }.ToJsonString();
        }
        else
        {
            var (sql, parameters) = row is null ? BuildInsert(table, userId, prepared) : BuildUpdate(table, prepared);
            var written = await db.SingleAsync<WrittenRow>(sql, parameters).ConfigureAwait(false);
            version = written.Version;
            operation = "upsert";
            change = prepared.ChangeJson;
            if (prepared.IsTrainingPlan && written.LineageId is { } lineageId)
            {
                var node = JsonNode.Parse(change)!.AsObject();
                node["lineageId"] = lineageId.ToString("D");
                change = node.ToJsonString();
            }
        }

        var seq = await db.ScalarAsync<long>(AdvanceSeqSql, new { userId }).ConfigureAwait(false);
        await db.ExecuteAsync(InsertChangeSql, new
        {
            userId,
            seq,
            entityType = mutation.EntityType,
            entityId = mutation.EntityId,
            operation,
            serverVersion = version,
            payload = change,
        }).ConfigureAwait(false);
        return SyncReceipt.Applied(mutation.MutationId, version);
    }

    private static (string Sql, DynamicParameters Parameters) BuildInsert(string table, Guid userId, PreparedMutation prepared)
    {
        var parameters = new DynamicParameters();
        parameters.Add("id", prepared.Mutation.EntityId);
        parameters.Add("userId", userId);
        var columns = new StringBuilder("id, user_id, version, updated_at");
        var values = new StringBuilder("@id, @userId, 1, clock_timestamp()");
        if (prepared.ServerCreatedAt)
        {
            columns.Append(", created_at");
            values.Append(", clock_timestamp()");
        }

        for (var i = 0; i < prepared.Columns.Count; i++)
        {
            var column = prepared.Columns[i];
            parameters.Add(ParameterName(i), column.Value, DbType.String);
            columns.Append(", ").Append(column.Name);
            values.Append(CultureInfo.InvariantCulture, $", CAST(@{ParameterName(i)} AS {column.SqlType})");
        }

        return (string.Create(CultureInfo.InvariantCulture,
            $"INSERT INTO {table} ({columns}) VALUES ({values}) RETURNING version AS Version{Returning(prepared)}"), parameters);
    }

    private static (string Sql, DynamicParameters Parameters) BuildUpdate(string table, PreparedMutation prepared)
    {
        var parameters = new DynamicParameters();
        parameters.Add("id", prepared.Mutation.EntityId);
        var assignments = new StringBuilder();
        for (var i = 0; i < prepared.Columns.Count; i++)
        {
            var column = prepared.Columns[i];
            parameters.Add(ParameterName(i), column.Value, DbType.String);
            assignments.Append(CultureInfo.InvariantCulture, $"{column.Name} = CAST(@{ParameterName(i)} AS {column.SqlType}), ");
        }

        return (string.Create(CultureInfo.InvariantCulture,
            $"UPDATE {table} SET {assignments}version = version + 1, updated_at = clock_timestamp() WHERE id = @id RETURNING version AS Version{Returning(prepared)}"),
            parameters);
    }

    private static string Returning(PreparedMutation prepared) => prepared.IsTrainingPlan ? ", lineage_id AS LineageId" : string.Empty;

    private static string ParameterName(int index) => string.Create(CultureInfo.InvariantCulture, $"p{index}");

    /// <summary>SQLSTATE → receipt (ADR-069). Null rethrows: an unmapped database error is a 500, never a silent receipt.</summary>
    private static SyncReceipt? Map(Guid mutationId, PostgresException e)
    {
        const string invalid = "The mutation violates a server rule.";
        return e.SqlState switch
        {
            ActivePlanLimitSqlState => SyncReceipt.Rejected(mutationId, ReceiptCodes.ActivePlanLimit,
                "Too many plans are followed on these dates.", "fromDate"),
            PlanCountLimitSqlState => SyncReceipt.Rejected(mutationId, ReceiptCodes.PlanCountLimit, "The plan limit is reached."),
            PinnedGoalLimitSqlState => SyncReceipt.Rejected(mutationId, ReceiptCodes.PinnedGoalLimit,
                "The pinned goal limit of this plan is reached.", "pinned"),
            GoalUnlockCycleSqlState => SyncReceipt.Rejected(mutationId, ReceiptCodes.GoalUnlockCycle,
                "unlockAfterGoalId would form a cycle.", "unlockAfterGoalId"),
            ExclusionViolationSqlState => SyncReceipt.Rejected(mutationId, ReceiptCodes.ValidationFailed,
                "The activation overlaps another activation of this plan.", "fromDate"),
            PostgresErrorCodes.ForeignKeyViolation => ForeignKeyFields.TryGetValue(e.ConstraintName ?? string.Empty, out var field)
                ? SyncReceipt.Rejected(mutationId, ReceiptCodes.ValidationFailed, "Must reference an existing published server row.", field)
                : SyncReceipt.DependencyMissing(mutationId, DependencyFields.GetValueOrDefault(e.ConstraintName ?? string.Empty),
                    "A referenced row does not exist on the server yet."),
            PostgresErrorCodes.CheckViolation => SyncReceipt.Rejected(mutationId, ReceiptCodes.ValidationFailed, invalid,
                CheckFields.GetValueOrDefault(e.ConstraintName ?? string.Empty)),
            PostgresErrorCodes.UniqueViolation when UniqueFields.TryGetValue(e.ConstraintName ?? string.Empty, out var field) =>
                SyncReceipt.Rejected(mutationId, ReceiptCodes.ValidationFailed, invalid, field),
            _ => null,
        };
    }

    // Catalog/config foreign keys: an unknown server-owned id never appears later, so it is not retryable.
    private static readonly Dictionary<string, string> ForeignKeyFields = new(StringComparer.Ordinal)
    {
        ["fk_plan_goals_indicator"] = "indicatorId",
        ["fk_plan_goals_exercise"] = "exerciseId",
        ["fk_set_results_criteria_version"] = "criteriaVersion",
        ["planned_exercises_exercise_id_fkey"] = "exerciseId",
        ["exercise_executions_exercise_id_fkey"] = "exerciseId",
    };

    private static readonly Dictionary<string, string> DependencyFields = new(StringComparer.Ordinal)
    {
        ["fk_plan_activations_lineage"] = "planLineageId",
        ["fk_plan_goals_lineage"] = "planLineageId",
    };

    private static readonly Dictionary<string, string> CheckFields = new(StringComparer.Ordinal)
    {
        ["ck_plan_goals_indicator_immutable"] = "indicatorId",
        ["ck_plan_goals_exercise_immutable"] = "exerciseId",
        ["ck_plan_goals_lineage_immutable"] = "planLineageId",
        ["ck_plan_phases_plan_immutable"] = "planId",
        ["ck_training_plans_lineage_parent"] = "lineageId",
        ["ck_plan_goals_scope_same_lineage"] = "scopePhaseId",
        ["ck_plan_goals_unlock_same_lineage"] = "unlockAfterGoalId",
        ["ck_plan_goals_unlock_not_self"] = "unlockAfterGoalId",
        ["ck_plan_goals_target"] = "target.max",
        ["ck_plan_goals_values"] = "target",
        ["ck_plan_goals_achieved_at"] = "achievedAt",
        ["ck_plan_activations_dates"] = "toDate",
        ["ck_plan_activations_end_reason_needs_to_date"] = "toDate",
        ["ck_training_plans_event_date"] = "eventDate",
        ["ck_training_plans_ended"] = "endReason",
        ["ck_training_plans_end_note"] = "endNote",
        ["ck_set_results_actual_load_kg"] = "actualLoadKg",
        ["ck_set_results_distance_meters"] = "distanceMeters",
        ["ck_set_results_duration_seconds"] = "durationSeconds",
        ["ck_set_results_source"] = "source",
        ["ck_body_measurements_value"] = "value",
        ["ck_body_measurements_kind"] = "kind",
        ["ck_set_results_criteria_pair"] = "criteria",
        ["ck_set_results_criteria"] = "criteria",
        ["ck_session_status_phase"] = "phase",
        ["ck_session_paused_at"] = "pausedAt",
        ["workout_sessions_check"] = "finishedAt",
    };

    private static readonly Dictionary<string, string> UniqueFields = new(StringComparer.Ordinal)
    {
        ["ux_session_one_active_per_user"] = "status",
        ["ux_set_results_execution_set_live"] = "setIndex",
        ["ux_training_plans_one_current_per_lineage"] = "status",
    };

    private sealed record StoredMutation(string PayloadSha256, string Receipt);

    private sealed record CurrentRow(Guid UserId, long Version, bool Deleted);

    private sealed record DeletedRow(long Version, DateTime DeletedAt);

    // A settable class, not a positional record: plain tables return only Version.
    private sealed class WrittenRow
    {
        public long Version { get; init; }

        public Guid? LineageId { get; init; }
    }

    private sealed class Db(NpgsqlConnection connection, NpgsqlTransaction transaction, CancellationToken cancellationToken)
    {
        public Task<int> ExecuteAsync(string sql, object parameters) =>
            connection.ExecuteAsync(new CommandDefinition(sql, parameters, transaction, cancellationToken: cancellationToken));

        public Task<T?> ScalarAsync<T>(string sql, object parameters) =>
            connection.ExecuteScalarAsync<T>(new CommandDefinition(sql, parameters, transaction, cancellationToken: cancellationToken));

        public Task<T?> SingleOrDefaultAsync<T>(string sql, object parameters) =>
            connection.QuerySingleOrDefaultAsync<T>(new CommandDefinition(sql, parameters, transaction, cancellationToken: cancellationToken));

        public Task<T> SingleAsync<T>(string sql, object parameters) =>
            connection.QuerySingleAsync<T>(new CommandDefinition(sql, parameters, transaction, cancellationToken: cancellationToken));
    }
}
