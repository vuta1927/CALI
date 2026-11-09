using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Cali.Application.Plans;

namespace Cali.Application.Sync;

/// <summary>
/// Per-entity payload rules of <c>POST /v1/sync/push</c> (contracts/entity-payloads.schema.json plus the
/// ADR-020 business rules that need no user data). Turns one envelope into a <see cref="PreparedMutation"/>:
/// the columns to write, the normalized change-log payload, the parent rows to check inside the
/// transaction, or the rejection receipt (ADR-069). Rules that need the user's rows (references,
/// versions, limits, overlaps, unlock cycles) are enforced by the writer and the database.
/// </summary>
public static class SyncEntitySpecs
{
    private static readonly Dictionary<string, string> Tables = new(StringComparer.Ordinal)
    {
        [SyncEntityTypes.TrainingPlan] = "training_plans",
        [SyncEntityTypes.PlannedWorkout] = "planned_workouts",
        [SyncEntityTypes.PlannedExercise] = "planned_exercises",
        [SyncEntityTypes.WorkoutSession] = "workout_sessions",
        [SyncEntityTypes.ExerciseExecution] = "exercise_executions",
        [SyncEntityTypes.SetResult] = "set_results",
        [SyncEntityTypes.WorkoutNote] = "workout_notes",
        [SyncEntityTypes.PlanActivation] = "plan_activations",
        [SyncEntityTypes.PlanPhase] = "plan_phases",
        [SyncEntityTypes.PlanGoal] = "plan_goals",
        [SyncEntityTypes.BodyMeasurement] = "body_measurements",
    };

    // Tables whose created_at is the server time of the first write; workout_notes takes it from the payload.
    private static readonly HashSet<string> ServerCreatedAtTables = new(StringComparer.Ordinal)
    {
        "training_plans", "plan_activations", "plan_phases", "plan_goals", "body_measurements",
    };

    private static readonly string[] PlanStatuses = ["current", "superseded"];
    private static readonly string[] PlanKinds = ["weekly", "event"];
    private static readonly string[] Disciplines = ["calisthenics", "running", "gym", "mixed"];
    private static readonly string[] PlanEndReasons = ["completed", "stopped"];
    private static readonly string[] SessionStatuses = ["active", "completed", "abandoned"];
    private static readonly string[] SessionPhases =
        ["ready", "pre_countdown", "exercising", "awaiting_result", "resting", "paused", "reviewing_summary", "completed", "abandoned"];
    private static readonly string[] SetStatuses = ["completed", "failed", "skipped"];
    private static readonly string[] SetSources = ["manual"];
    private static readonly string[] ActivationEndReasons = ["paused", "completed", "stopped", "deleted"];
    private static readonly string[] GoalStatuses = ["active", "reached", "achieved", "missed", "archived"];
    private static readonly string[] BodyKinds = ["weight"];

    /// <summary>Catalog ids and criteria versions the batch refers to, so the lookups can be loaded in one go.</summary>
    public static (IReadOnlyCollection<Guid> ExerciseIds, IReadOnlyCollection<int> CriteriaVersions, bool NeedsIndicators) LookupKeys(
        IEnumerable<SyncMutation> mutations)
    {
        ArgumentNullException.ThrowIfNull(mutations);
        var exerciseIds = new HashSet<Guid>();
        var versions = new HashSet<int>();
        var indicators = false;
        foreach (var mutation in mutations.Where(m => m.Action == SyncActions.Upsert))
        {
            AddUuid(mutation.Payload, "exerciseId", exerciseIds);
            if (mutation.Payload.TryGetProperty("prescribedSnapshot", out var snapshot) && snapshot.ValueKind == JsonValueKind.Object)
            {
                AddUuid(snapshot, "exerciseId", exerciseIds);
            }

            if (mutation.Payload.TryGetProperty("criteriaVersion", out var version) && version.ValueKind == JsonValueKind.Number
                && version.TryGetInt32(out var number) && number >= 1)
            {
                versions.Add(number);
            }

            indicators |= mutation.EntityType == SyncEntityTypes.PlanGoal;
        }

        return (exerciseIds, versions, indicators);
    }

    public static PreparedMutation Prepare(SyncMutation mutation, SyncLookups lookups)
    {
        ArgumentNullException.ThrowIfNull(mutation);
        ArgumentNullException.ThrowIfNull(lookups);
        var fingerprint = mutation.Fingerprint();
        if (!Tables.TryGetValue(mutation.EntityType, out var table))
        {
            var forbidden = SyncReceipt.Rejected(mutation.MutationId, ReceiptCodes.ForbiddenEntity,
                "This entity type cannot be written through sync push.", "entityType");
            return new PreparedMutation(mutation, fingerprint, null, [], "{}", [], forbidden, false);
        }

        var errors = new ValidationErrors();
        var reader = new PayloadReader(mutation.Payload, errors);
        var references = new List<SyncReference>();
        var id = reader.Uuid("id", null, required: true);
        if (id is { } payloadId && payloadId != mutation.EntityId)
        {
            errors.Add("id", "Must equal entityId.");
        }

        if (mutation.Action == SyncActions.Delete)
        {
            reader.DateTime("deletedAt", null, required: true);
        }
        else
        {
            var context = new SpecContext(reader, mutation, lookups, references);
            switch (mutation.EntityType)
            {
                case SyncEntityTypes.TrainingPlan: TrainingPlan(context); break;
                case SyncEntityTypes.PlannedWorkout: PlannedWorkout(context); break;
                case SyncEntityTypes.PlannedExercise: PlannedExercise(context); break;
                case SyncEntityTypes.WorkoutSession: WorkoutSession(context); break;
                case SyncEntityTypes.ExerciseExecution: ExerciseExecution(context); break;
                case SyncEntityTypes.SetResult: SetResult(context); break;
                case SyncEntityTypes.WorkoutNote: WorkoutNote(context); break;
                case SyncEntityTypes.PlanActivation: PlanActivation(context); break;
                case SyncEntityTypes.PlanPhase: PlanPhase(context); break;
                case SyncEntityTypes.PlanGoal: PlanGoal(context); break;
                case SyncEntityTypes.BodyMeasurement: BodyMeasurement(context); break;
                default: throw new InvalidOperationException("Unhandled entity type.");
            }
        }

        reader.Finish();
        SyncReceipt? rejection = null;
        if (errors.HasErrors)
        {
            var (field, messages) = errors.ToDictionary().First(e => e.Key == errors.Fields.First());
            rejection = SyncReceipt.Rejected(mutation.MutationId, ReceiptCodes.ValidationFailed, messages[0], field);
        }

        return new PreparedMutation(mutation, fingerprint, table, reader.Columns, reader.Change.ToJsonString(), references,
            rejection, ServerCreatedAtTables.Contains(table));
    }

    private sealed record SpecContext(PayloadReader Reader, SyncMutation Mutation, SyncLookups Lookups, List<SyncReference> References)
    {
        public ValidationErrors Errors => Reader.Errors;

        public void Parent(string field, string table, Guid? id)
        {
            if (id is { } value)
            {
                References.Add(new ParentReference(field, table, value));
            }
        }
    }

    private static void TrainingPlan(SpecContext c)
    {
        var r = c.Reader;
        r.Text("title", "title", required: true, 1, PlanValidator.MaxTitleLength);
        r.Integer("revision", "revision", required: true, 1, int.MaxValue);
        r.Enum("status", "status", required: true, PlanStatuses);
        c.Parent("parentPlanId", "training_plans", r.Uuid("parentPlanId", "parent_plan_id", required: false, nullable: true));

        // Omitted lineageId: the column is left out and trg_training_plans_lineage derives it (ADR-036).
        r.Uuid("lineageId", "lineage_id", required: false);
        var kind = r.Enum("kind", "kind", required: false, PlanKinds, defaultValue: "weekly");
        var eventDate = r.Date("eventDate", "event_date", required: false, nullable: true);
        r.Text("eventName", "event_name", required: false, 1, PlanValidator.MaxEventNameLength, nullable: true);
        r.Enum("primaryDiscipline", "primary_discipline", required: false, Disciplines, defaultValue: "calisthenics");
        r.DateTime("endedAt", "ended_at", required: false, nullable: true);
        r.Enum("endReason", "end_reason", required: false, PlanEndReasons, nullable: true);
        r.Text("endNote", "end_note", required: false, 0, 500, nullable: true);
        r.DateTime("archivedAt", "archived_at", required: false, nullable: true);
        if (kind == "event" && eventDate is null && !c.Errors.Fields.Contains("eventDate"))
        {
            c.Errors.Add("eventDate", "Required for an event plan.");
        }
    }

    private static void PlannedWorkout(SpecContext c)
    {
        var r = c.Reader;
        c.Parent("planId", "training_plans", r.Uuid("planId", "plan_id", required: true));
        r.Integer("weekday", "weekday", required: true, 1, 7);
        r.Text("title", "title", required: false, 0, PlanValidator.MaxTitleLength, defaultValue: string.Empty);
        r.Integer("orderIndex", "order_index", required: true, 0, int.MaxValue);
    }

    private static void PlannedExercise(SpecContext c)
    {
        var r = c.Reader;
        c.Parent("plannedWorkoutId", "planned_workouts", r.Uuid("plannedWorkoutId", "planned_workout_id", required: true));
        var exerciseId = r.Uuid("exerciseId", "exercise_id", required: true);
        string? exerciseType = null;
        if (exerciseId is { } value && !c.Lookups.PublishedExerciseTypes.TryGetValue(value, out exerciseType))
        {
            c.Errors.Add("exerciseId", "Must be a published catalog exercise.");
        }

        r.Integer("orderIndex", "order_index", required: true, 0, int.MaxValue);
        r.Integer("setCount", "set_count", required: true, 1, 20);
        if (PlanValidator.NormalizeTarget(r.Raw("target"), exerciseType, string.Empty, c.Errors) is { } target)
        {
            var text = target.GetRawText();
            r.Bind("target", "jsonb", text);
            r.Change["target"] = JsonNode.Parse(text);
        }

        r.Integer("restSeconds", "rest_seconds", required: true, 0, 3600);
    }

    private static void WorkoutSession(SpecContext c)
    {
        var r = c.Reader;
        c.Parent("plannedWorkoutId", "planned_workouts", r.Uuid("plannedWorkoutId", "planned_workout_id", required: false, nullable: true));
        r.Date("localDate", "local_date", required: true);
        r.Text("timezone", "timezone", required: true, 1, 64);
        var status = r.Enum("status", "status", required: true, SessionStatuses);
        var phase = r.Enum("phase", "phase", required: true, SessionPhases);
        var startedAt = r.DateTime("startedAt", "started_at", required: true);
        var finishedAt = r.DateTime("finishedAt", "finished_at", required: false, nullable: true);
        r.DateTime("phaseStartedAt", "phase_started_at", required: false, nullable: true);
        r.DateTime("phaseDeadlineAt", "phase_deadline_at", required: false, nullable: true);

        // Checked before the write: the FK is deferred to commit, where it could not become a receipt.
        c.Parent("currentExecutionId", "exercise_executions", r.Uuid("currentExecutionId", "current_execution_id", required: false, nullable: true));
        r.Integer("currentSetIndex", "current_set_index", required: false, 1, int.MaxValue, nullable: true);
        var pausedAt = r.DateTime("pausedAt", "paused_at", required: false, nullable: true);
        r.Integer("accumulatedExerciseMs", "accumulated_exercise_ms", required: false, 0, long.MaxValue, nullable: true, sqlType: "bigint");
        r.Text("abandonReason", "abandon_reason", required: false, 0, 500, nullable: true);

        // ADR-023: terminal status and terminal phase move together.
        if (status is not null && phase is not null
            && ((status == "completed") != (phase == "completed") || (status == "abandoned") != (phase == "abandoned")))
        {
            c.Errors.Add("phase", "Terminal status and phase must match (completed/completed, abandoned/abandoned).");
        }

        if (pausedAt is not null && phase is not null && phase != "paused")
        {
            c.Errors.Add("pausedAt", "Must be null unless the phase is paused.");
        }

        if (finishedAt is { } finished && startedAt is { } started && finished < started)
        {
            c.Errors.Add("finishedAt", "Must not be before startedAt.");
        }
    }

    private static void ExerciseExecution(SpecContext c)
    {
        var r = c.Reader;
        c.Parent("sessionId", "workout_sessions", r.Uuid("sessionId", "session_id", required: true));
        c.Parent("plannedExerciseId", "planned_exercises", r.Uuid("plannedExerciseId", "planned_exercise_id", required: false, nullable: true));

        // The catalog row itself is guarded by the FK (a retired exercise keeps its history); a published
        // exercise also fixes the snapshot target kind.
        var exerciseId = r.Uuid("exerciseId", "exercise_id", required: true);
        r.Integer("orderIndex", "order_index", required: true, 0, int.MaxValue);
        var exerciseType = exerciseId is { } value && c.Lookups.PublishedExerciseTypes.TryGetValue(value, out var type) ? type : null;
        Snapshot(c, exerciseType);
    }

    private static void SetResult(SpecContext c)
    {
        var r = c.Reader;
        c.Parent("executionId", "exercise_executions", r.Uuid("executionId", "execution_id", required: true));
        r.Integer("setIndex", "set_index", required: true, 1, 100);
        var status = r.Enum("status", "status", required: true, SetStatuses);
        var kind = Snapshot(c, exerciseType: null);
        var actualReps = r.Integer("actualReps", "actual_reps", required: false, 0, int.MaxValue, nullable: true);
        r.Integer("actualHoldMs", "actual_hold_ms", required: false, 0, long.MaxValue, nullable: true, sqlType: "bigint");
        r.Integer("actualWorkMs", "actual_work_ms", required: false, 0, long.MaxValue, nullable: true, sqlType: "bigint");
        r.Integer("actualRestMs", "actual_rest_ms", required: false, 0, long.MaxValue, nullable: true, sqlType: "bigint");
        var distance = r.Integer("distanceMeters", "distance_meters", required: false, 0, 1_000_000, nullable: true);
        var duration = r.Integer("durationSeconds", "duration_seconds", required: false, 0, 86_400, nullable: true);
        r.Enum("source", "source", required: false, SetSources, defaultValue: "manual");
        var load = r.Number("actualLoadKg", "actual_load_kg", required: false, 0, 1000, maxDecimals: 2, nullable: true);
        r.Integer("rpe", "rpe", required: false, 1, 10, nullable: true);
        r.Text("note", "note", required: false, 0, 1000, nullable: true);
        r.Text("skipReason", "skip_reason", required: false, 0, 500, nullable: true);
        r.Bool("painReported", "pain_reported", required: false, defaultValue: false);
        r.DateTime("confirmedAt", "confirmed_at", required: true);
        r.Integer("revision", "revision", required: false, 1, int.MaxValue, defaultValue: 1);
        Criteria(c);

        if (kind is null)
        {
            return;
        }

        var completed = status == "completed";
        if ((distance is not null || duration is not null) && kind is not ("distance" or "duration"))
        {
            c.Errors.Add("distanceMeters", "distanceMeters and durationSeconds are only for a distance or duration target.");
        }
        else if (completed && kind == "distance" && (distance is not > 0 || duration is not > 0))
        {
            c.Errors.Add("distanceMeters", "A completed distance set needs distanceMeters and durationSeconds above 0.");
        }
        else if (completed && kind == "duration" && duration is not > 0)
        {
            c.Errors.Add("durationSeconds", "A completed duration set needs durationSeconds above 0.");
        }

        if (load is not null && kind != "load")
        {
            c.Errors.Add("actualLoadKg", "Only for a load target.");
        }
        else if (completed && kind == "load" && (actualReps is null || load is null))
        {
            c.Errors.Add("actualLoadKg", "A completed load set needs actualReps and actualLoadKg.");
        }
    }

    private static void WorkoutNote(SpecContext c)
    {
        var r = c.Reader;
        c.Parent("sessionId", "workout_sessions", r.Uuid("sessionId", "session_id", required: true));
        r.Text("noteText", "note_text", required: true, 0, 10_000);
        r.DateTime("createdAt", "created_at", required: true);
    }

    private static void PlanActivation(SpecContext c)
    {
        var r = c.Reader;
        if (r.Uuid("planLineageId", "plan_lineage_id", required: true) is { } lineage)
        {
            c.References.Add(new LineageReference("planLineageId", lineage));
        }

        var from = r.Date("fromDate", "from_date", required: true);
        var to = r.Date("toDate", "to_date", required: false, nullable: true);
        var timezone = r.Text("timezone", "timezone", required: true, 1, 64);
        var endReason = r.Enum("endReason", "end_reason", required: false, ActivationEndReasons, nullable: true);
        TimeZoneInfo? zone = null;
        if (timezone is not null && !TimeZoneInfo.TryFindSystemTimeZoneById(timezone, out zone))
        {
            c.Errors.Add("timezone", "Must be an IANA time zone.");
        }

        if (from is { } start && to is { } end && end < start)
        {
            c.Errors.Add("toDate", "Must not be before fromDate.");
        }
        else if (endReason is not null && to is null && !c.Errors.Fields.Contains("toDate"))
        {
            c.Errors.Add("toDate", "Required when endReason is set.");
        }

        // BR-1: a new activation never starts in the past of its own time zone.
        if (c.Mutation.BaseVersion == 0 && from is { } first && zone is not null
            && first < DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(c.Mutation.ClientChangedAt, zone).DateTime))
        {
            c.Errors.Add("fromDate", "Must not be before today in the activation time zone.");
        }
    }

    private static void PlanPhase(SpecContext c)
    {
        var r = c.Reader;
        c.Parent("planId", "training_plans", r.Uuid("planId", "plan_id", required: true));
        r.Integer("orderIndex", "order_index", required: true, 0, int.MaxValue);
        r.Text("name", "name", required: true, 1, 120);
        r.Integer("weeks", "weeks", required: true, 1, 52);
        r.Text("description", "description", required: false, 0, 500, nullable: true);
    }

    private static void PlanGoal(SpecContext c)
    {
        var r = c.Reader;
        if (r.Uuid("planLineageId", "plan_lineage_id", required: true) is { } lineage)
        {
            c.References.Add(new LineageReference("planLineageId", lineage));
        }

        r.Text("title", "title", required: true, 1, 120);
        var indicatorId = r.Text("indicatorId", "indicator_id", required: true, 1, 64);
        var hadExerciseError = c.Errors.Fields.Contains("exerciseId");
        var exerciseId = r.Uuid("exerciseId", "exercise_id", required: false, nullable: true);
        if (indicatorId is not null && (hadExerciseError || !c.Errors.Fields.Contains("exerciseId"))
            && IndicatorRules.Check(indicatorId, exerciseId, c.Lookups) is { } problem)
        {
            c.Errors.Add(problem.Field, problem.Message);
        }

        r.Number("baseline", "baseline", required: false, 0, 999_999_999, maxDecimals: 3, nullable: true);
        GoalTarget(c);
        c.Parent("scopePhaseId", "plan_phases", r.Uuid("scopePhaseId", "scope_phase_id", required: false, nullable: true));
        var unlockAfter = r.Uuid("unlockAfterGoalId", "unlock_after_goal_id", required: false, nullable: true);
        if (unlockAfter is { } after && after == c.Mutation.EntityId)
        {
            c.Errors.Add("unlockAfterGoalId", "A goal cannot unlock after itself.");
        }
        else
        {
            c.Parent("unlockAfterGoalId", "plan_goals", unlockAfter);
        }

        var status = r.Enum("status", "status", required: true, GoalStatuses);
        var achievedAt = r.DateTime("achievedAt", "achieved_at", required: false, nullable: true);
        r.Bool("pinned", "pinned", required: true);
        r.Text("note", "note", required: false, 0, 500, nullable: true);

        // "Achieved" is a user confirmation with its time (docs/18 §6.2, AGENTS rules 3 and 5).
        if (status == "achieved" && achievedAt is null && !c.Errors.Fields.Contains("achievedAt"))
        {
            c.Errors.Add("achievedAt", "Required when status is achieved.");
        }
        else if (status is "active" or "reached" or "missed" && achievedAt is not null)
        {
            c.Errors.Add("achievedAt", "Must be null unless the goal is achieved or archived.");
        }
    }

    private static void BodyMeasurement(SpecContext c)
    {
        var r = c.Reader;
        r.Enum("kind", "kind", required: true, BodyKinds);

        // ADR-063/064: excess decimals are rejected, never rounded; messages never echo the value.
        r.Number("value", "value", required: true, 20, 500, maxDecimals: 2);
        if (r.DateTime("measuredAt", "measured_at", required: true) is { } measuredAt && measuredAt > c.Mutation.ClientChangedAt)
        {
            c.Errors.Add("measuredAt", "Must not be after clientChangedAt.");
        }
    }

    /// <summary>
    /// Validates and binds <c>prescribedSnapshot</c> (ADR-018). Returns the normalized target kind, or null
    /// when the snapshot is invalid. Without <paramref name="exerciseType"/> the snapshot's own exerciseId
    /// fixes the kind when it is a published exercise; otherwise only the shape is checked.
    /// </summary>
    private static string? Snapshot(SpecContext c, string? exerciseType)
    {
        const string Field = "prescribedSnapshot";
        var raw = c.Reader.Raw(Field);
        if (raw is not { ValueKind: JsonValueKind.Object } snapshot)
        {
            c.Errors.Add(Field, raw is null ? PlanValidator.Required : "Must be a prescribed snapshot object.");
            return null;
        }

        var local = new ValidationErrors();
        var sub = new PayloadReader(snapshot, local);
        var targetRaw = sub.Raw("target");
        sub.Integer("setCount", null, required: true, 1, 20);
        sub.Integer("restSeconds", null, required: true, 0, 3600);
        sub.Integer("catalogVersion", null, required: true, 1, int.MaxValue);
        var exerciseId = sub.Uuid("exerciseId", null, required: false);
        if (sub.Has("plannedExerciseId"))
        {
            sub.Uuid("plannedExerciseId", null, required: false, nullable: true);
        }
        else
        {
            sub.Raw("plannedExerciseId");
        }

        if (exerciseType is null && exerciseId is { } id && c.Lookups.PublishedExerciseTypes.TryGetValue(id, out var type))
        {
            exerciseType = type;
        }

        var target = PlanValidator.NormalizeTarget(targetRaw, exerciseType, string.Empty, local);
        sub.Finish();
        foreach (var (field, messages) in local.ToDictionary())
        {
            foreach (var message in messages)
            {
                c.Errors.Add($"{Field}.{field}", message);
            }
        }

        if (local.HasErrors || target is not { } normalized)
        {
            return null;
        }

        var node = new JsonObject { ["target"] = JsonNode.Parse(normalized.GetRawText()) };
        foreach (var (name, value) in sub.Change)
        {
            node[name] = value?.DeepClone();
        }

        var text = node.ToJsonString();
        c.Reader.Bind("prescribed_snapshot", "jsonb", text);
        c.Reader.Change[Field] = node;
        return normalized.GetProperty("kind").GetString();
    }

    /// <summary>criteria and criteriaVersion (CON-008, ADR-067); both omitted stores NULL for both.</summary>
    private static void Criteria(SpecContext c)
    {
        var r = c.Reader;
        var hasVersion = r.Has("criteriaVersion");
        var version = r.Integer("criteriaVersion", "criteria_version", required: false, 1, int.MaxValue);
        if (!hasVersion)
        {
            r.Bind("criteria_version", "integer", null);
        }

        var criteria = r.Raw("criteria");
        if (criteria is null)
        {
            r.Bind("criteria", "jsonb", null);
            if (hasVersion)
            {
                c.Errors.Add("criteria", "Required with criteriaVersion.");
            }

            return;
        }

        if (CriteriaRules.CheckShape(criteria.Value) is { } shapeProblem)
        {
            c.Errors.Add("criteria", shapeProblem);
            return;
        }

        if (!hasVersion)
        {
            c.Errors.Add("criteria", "criteriaVersion is required with criteria.");
            return;
        }

        if (version is not { } v)
        {
            return;
        }

        if (!c.Lookups.CriteriaDocuments.TryGetValue((int)v, out var document))
        {
            c.Errors.Add("criteriaVersion", "Must be a published criteria config version.");
            return;
        }

        if (CriteriaRules.CheckAgainstDocument(criteria.Value, document) is { } problem)
        {
            c.Errors.Add("criteria", problem);
            return;
        }

        var text = criteria.Value.GetRawText();
        r.Bind("criteria", "jsonb", text);
        r.Change["criteria"] = JsonNode.Parse(text);
    }

    /// <summary>A goal target is <c>{value}</c> or <c>{min, max}</c> (CON-005); numeric(12,3) is never rounded.</summary>
    private static void GoalTarget(SpecContext c)
    {
        const string Field = "target";
        var r = c.Reader;
        var raw = r.Raw(Field);
        if (raw is not { ValueKind: JsonValueKind.Object } target)
        {
            c.Errors.Add(Field, raw is null ? PlanValidator.Required : "Must be a goal target object.");
            return;
        }

        var local = new ValidationErrors();
        var sub = new PayloadReader(target, local);
        decimal? value = null, min = null, max = null;
        if (sub.Has("value") && (sub.Has("min") || sub.Has("max")))
        {
            c.Errors.Add(Field, "Use either value or min and max.");
            return;
        }

        if (sub.Has("value"))
        {
            value = sub.Number("value", null, required: true, 0, 999_999_999, maxDecimals: 3);
        }
        else
        {
            min = sub.Number("min", null, required: true, 0, 999_999_999, maxDecimals: 3);
            max = sub.Number("max", null, required: true, 0, 999_999_999, maxDecimals: 3);
            if (min is { } lo && max is { } hi && lo > hi)
            {
                local.Add("max", "Must be at least min.");
            }
        }

        sub.Finish();
        foreach (var (field, messages) in local.ToDictionary())
        {
            foreach (var message in messages)
            {
                c.Errors.Add($"{Field}.{field}", message);
            }
        }

        if (local.HasErrors)
        {
            return;
        }

        r.Bind("target_value", "numeric", value?.ToString(CultureInfo.InvariantCulture));
        r.Bind("target_min", "numeric", min?.ToString(CultureInfo.InvariantCulture));
        r.Bind("target_max", "numeric", max?.ToString(CultureInfo.InvariantCulture));
        r.Change[Field] = sub.Change.DeepClone();
    }

    private static void AddUuid(JsonElement payload, string field, HashSet<Guid> ids)
    {
        if (payload.TryGetProperty(field, out var element) && element.ValueKind == JsonValueKind.String
            && PayloadReader.TryParseUuid(element.GetString()!, out var id))
        {
            ids.Add(id);
        }
    }
}
