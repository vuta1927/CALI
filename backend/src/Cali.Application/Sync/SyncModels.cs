using System.Text.Json;
using System.Text.Json.Nodes;

namespace Cali.Application.Sync;

/// <summary>Entity types a device may write through <c>POST /v1/sync/push</c> (OpenAPI SyncMutation, db/007).</summary>
public static class SyncEntityTypes
{
    public const string TrainingPlan = "training_plan";
    public const string PlannedWorkout = "planned_workout";
    public const string PlannedExercise = "planned_exercise";
    public const string WorkoutSession = "workout_session";
    public const string ExerciseExecution = "exercise_execution";
    public const string SetResult = "set_result";
    public const string WorkoutNote = "workout_note";
    public const string PlanActivation = "plan_activation";
    public const string PlanPhase = "plan_phase";
    public const string PlanGoal = "plan_goal";
    public const string BodyMeasurement = "body_measurement";

    public static IReadOnlyList<string> All { get; } =
    [
        TrainingPlan, PlannedWorkout, PlannedExercise, WorkoutSession, ExerciseExecution, SetResult,
        WorkoutNote, PlanActivation, PlanPhase, PlanGoal, BodyMeasurement,
    ];

    public static bool IsWritable(string entityType) => All.Contains(entityType, StringComparer.Ordinal);
}

public static class SyncActions
{
    public const string Upsert = "upsert";
    public const string Delete = "delete";
}

public static class ReceiptStatuses
{
    public const string Applied = "applied";
    public const string Duplicate = "duplicate";
    public const string Conflict = "conflict";
    public const string Rejected = "rejected";
}

/// <summary>OpenAPI MutationError codes (ADR-021).</summary>
public static class ReceiptCodes
{
    public const string DependencyMissing = "dependency_missing";
    public const string VersionConflict = "version_conflict";
    public const string ValidationFailed = "validation_failed";
    public const string ForbiddenEntity = "forbidden_entity";
    public const string CrossUserReference = "cross_user_reference";
    public const string MutationIdReused = "mutation_id_reused";
    public const string ActivePlanLimit = "active_plan_limit";
    public const string PlanCountLimit = "plan_count_limit";
    public const string PinnedGoalLimit = "pinned_goal_limit";
    public const string GoalUnlockCycle = "goal_unlock_cycle";
}

/// <summary>One validated envelope of a push batch (OpenAPI SyncMutation).</summary>
public sealed record SyncMutation(
    Guid MutationId,
    string EntityType,
    Guid EntityId,
    string Action,
    long BaseVersion,
    DateTimeOffset ClientChangedAt,
    JsonElement Payload)
{
    /// <summary>
    /// ADR-031 / ADR-069: SHA-256 of the canonical form of <c>{entityType, entityId, action, baseVersion,
    /// payload}</c>; <c>clientChangedAt</c> is excluded so a resend with a new timestamp still replays.
    /// </summary>
    public string Fingerprint()
    {
        var node = new JsonObject
        {
            ["entityType"] = EntityType,
            ["entityId"] = EntityId.ToString("D"),
            ["action"] = Action,
            ["baseVersion"] = BaseVersion,
            ["payload"] = JsonNode.Parse(Payload.GetRawText()),
        };
        using var document = JsonDocument.Parse(node.ToJsonString());
        return Plans.PlanRequestHash.Compute(document.RootElement);
    }
}

public sealed record SyncPushBatch(Guid DeviceId, IReadOnlyList<SyncMutation> Mutations);

public sealed record ReceiptError(string Code, string Message, bool Retryable, string? Field);

/// <summary>Per-mutation result (OpenAPI SyncMutationResult).</summary>
public sealed record SyncReceipt(Guid MutationId, string Status, long? ServerVersion, string? ServerEntityJson, ReceiptError? Error)
{
    /// <summary>
    /// Non-retryable outcomes are stored and replayed for the same mutationId; <c>dependency_missing</c>,
    /// <c>mutation_id_reused</c> and <c>forbidden_entity</c> are not (ADR-021, ADR-069).
    /// </summary>
    public bool IsStored => Status == ReceiptStatuses.Applied
        || (Error is { Retryable: false } e && e.Code is not (ReceiptCodes.MutationIdReused or ReceiptCodes.ForbiddenEntity));

    public static SyncReceipt Applied(Guid mutationId, long version) => new(mutationId, ReceiptStatuses.Applied, version, null, null);

    public static SyncReceipt Rejected(Guid mutationId, string code, string message, string? field = null) =>
        new(mutationId, ReceiptStatuses.Rejected, null, null, new ReceiptError(code, message, false, field));

    public static SyncReceipt DependencyMissing(Guid mutationId, string? field, string message) =>
        new(mutationId, ReceiptStatuses.Conflict, null, null, new ReceiptError(ReceiptCodes.DependencyMissing, message, true, field));

    public static SyncReceipt VersionConflict(Guid mutationId, long? serverVersion, string? serverEntityJson) =>
        new(mutationId, ReceiptStatuses.Conflict, serverVersion, serverEntityJson,
            new ReceiptError(ReceiptCodes.VersionConflict, "baseVersion does not match the server version.", false, null));

    public JsonObject ToJson()
    {
        var json = new JsonObject
        {
            ["mutationId"] = MutationId.ToString("D"),
            ["status"] = Status,
            ["serverVersion"] = ServerVersion,
            ["serverEntity"] = ServerEntityJson is null ? null : JsonNode.Parse(ServerEntityJson),
            ["error"] = null,
        };
        if (Error is { } error)
        {
            var errorJson = new JsonObject
            {
                ["code"] = error.Code,
                ["message"] = error.Message,
                ["retryable"] = error.Retryable,
            };
            if (error.Field is not null)
            {
                errorJson["details"] = new JsonObject { ["field"] = error.Field };
            }

            json["error"] = errorJson;
        }

        return json;
    }

    /// <summary>Reads a receipt stored by <see cref="ToJson"/> (sync_mutations.receipt).</summary>
    public static SyncReceipt FromJson(string json)
    {
        ArgumentNullException.ThrowIfNull(json);
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        long? version = root.TryGetProperty("serverVersion", out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : null;
        string? entity = root.TryGetProperty("serverEntity", out var e) && e.ValueKind == JsonValueKind.Object ? e.GetRawText() : null;
        ReceiptError? error = null;
        if (root.TryGetProperty("error", out var err) && err.ValueKind == JsonValueKind.Object)
        {
            string? field = err.TryGetProperty("details", out var d) && d.ValueKind == JsonValueKind.Object
                && d.TryGetProperty("field", out var f) && f.ValueKind == JsonValueKind.String ? f.GetString() : null;
            error = new ReceiptError(err.GetProperty("code").GetString()!, err.GetProperty("message").GetString()!,
                err.GetProperty("retryable").GetBoolean(), field);
        }

        return new SyncReceipt(Guid.Parse(root.GetProperty("mutationId").GetString()!), root.GetProperty("status").GetString()!, version, entity, error);
    }
}
