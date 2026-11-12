using System.Globalization;
using System.Text.Json;
using Cali.Application.Plans;
using Cali.Domain.Plans;
using Dapper;
using Npgsql;

namespace Cali.Infrastructure.Persistence;

/// <summary>Reads a user's plan revisions. Every query filters on <c>user_id</c> (no cross-user reads).</summary>
public sealed class PlanReader(NpgsqlDataSource dataSource) : IPlanReader
{
    // Keyset pagination on (created_at, id): both immutable, so concurrent inserts never shift pages.
    private const string PlansSql = """
        SELECT id AS Id, title AS Title, kind AS Kind, event_date::text AS EventDate, event_name AS EventName,
               primary_discipline AS PrimaryDiscipline, revision AS Revision, version AS Version, status AS Status,
               parent_plan_id AS ParentPlanId, lineage_id AS LineageId, ended_at AS EndedAt, end_reason AS EndReason,
               end_note AS EndNote, archived_at AS ArchivedAt, created_at AS CreatedAt
        FROM training_plans
        WHERE user_id = @userId AND deleted_at IS NULL
          AND (CAST(@afterCreatedAt AS timestamptz) IS NULL
               OR (created_at, id) > (CAST(@afterCreatedAt AS timestamptz), CAST(@afterId AS uuid)))
        ORDER BY created_at, id
        LIMIT @take
        """;

    private const string WorkoutsSql = """
        SELECT id AS Id, plan_id AS PlanId, weekday AS Weekday, title AS Title, order_index AS OrderIndex,
               rest_between_exercises_seconds AS RestBetweenExercisesSeconds
        FROM planned_workouts
        WHERE user_id = @userId AND plan_id = ANY(@planIds) AND deleted_at IS NULL
        ORDER BY weekday, order_index, id
        """;

    private const string ExercisesSql = """
        SELECT id AS Id, planned_workout_id AS PlannedWorkoutId, exercise_id AS ExerciseId, order_index AS OrderIndex,
               set_count AS SetCount, target::text AS TargetJson, rest_seconds AS RestSeconds
        FROM planned_exercises
        WHERE user_id = @userId AND planned_workout_id = ANY(@workoutIds) AND deleted_at IS NULL
        ORDER BY order_index, id
        """;

    private const string ExerciseTypesSql = """
        SELECT id AS Id, exercise_type AS Type
        FROM exercise_catalog
        WHERE is_published AND id = ANY(@ids)
        """;

    public async Task<IReadOnlyList<PlanListItem>> ListAsync(Guid userId, PlanCursor? after, int take, CancellationToken cancellationToken)
    {
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        var plans = (await connection.QueryAsync<PlanRow>(new CommandDefinition(
            PlansSql,
            new
            {
                userId,
                afterCreatedAt = after is null ? (DateTime?)null : DateTime.SpecifyKind(after.CreatedAtUtc, DateTimeKind.Utc),
                afterId = after?.Id,
                take,
            },
            cancellationToken: cancellationToken)).ConfigureAwait(false)).AsList();
        if (plans.Count == 0)
        {
            return [];
        }

        var workouts = (await connection.QueryAsync<WorkoutRow>(new CommandDefinition(
            WorkoutsSql, new { userId, planIds = plans.Select(p => p.Id).ToArray() }, cancellationToken: cancellationToken))
            .ConfigureAwait(false)).AsList();
        var exercises = workouts.Count == 0
            ? []
            : (await connection.QueryAsync<ExerciseRow>(new CommandDefinition(
                ExercisesSql, new { userId, workoutIds = workouts.Select(w => w.Id).ToArray() }, cancellationToken: cancellationToken))
                .ConfigureAwait(false)).AsList();

        var exercisesByWorkout = exercises.ToLookup(e => e.PlannedWorkoutId);
        var workoutsByPlan = workouts.ToLookup(w => w.PlanId);
        return plans.Select(p => new PlanListItem(
            new TrainingPlan(
                p.Id, p.Title, p.Kind,
                p.EventDate is null ? null : DateOnly.ParseExact(p.EventDate, "yyyy-MM-dd", CultureInfo.InvariantCulture),
                p.EventName, p.PrimaryDiscipline,
                workoutsByPlan[p.Id].Select(w => new PlannedWorkout(
                    w.Id, w.Weekday, w.Title, w.OrderIndex,
                    exercisesByWorkout[w.Id].Select(ToExercise).ToArray(), w.RestBetweenExercisesSeconds)).ToArray(),
                p.Revision, p.Version, p.Status, p.ParentPlanId, p.LineageId,
                Utc(p.EndedAt), p.EndReason, p.EndNote, Utc(p.ArchivedAt)),
            DateTime.SpecifyKind(p.CreatedAt, DateTimeKind.Utc))).ToArray();
    }

    public async Task<IReadOnlyDictionary<Guid, string>> GetPublishedExerciseTypesAsync(
        IReadOnlyCollection<Guid> exerciseIds, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(exerciseIds);
        if (exerciseIds.Count == 0)
        {
            return new Dictionary<Guid, string>();
        }

        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        var rows = await connection.QueryAsync<ExerciseTypeRow>(new CommandDefinition(
            ExerciseTypesSql, new { ids = exerciseIds.ToArray() }, cancellationToken: cancellationToken)).ConfigureAwait(false);
        return rows.ToDictionary(r => r.Id, r => r.Type);
    }

    private static PlannedExercise ToExercise(ExerciseRow row)
    {
        using var target = JsonDocument.Parse(row.TargetJson);
        return new PlannedExercise(row.Id, row.ExerciseId, row.OrderIndex, row.SetCount, target.RootElement.Clone(), row.RestSeconds);
    }

    private static DateTimeOffset? Utc(DateTime? value) =>
        value is { } v ? new DateTimeOffset(DateTime.SpecifyKind(v, DateTimeKind.Utc)) : null;

    private sealed class PlanRow
    {
        public Guid Id { get; init; }
        public string Title { get; init; } = "";
        public string Kind { get; init; } = "";
        public string? EventDate { get; init; }
        public string? EventName { get; init; }
        public string PrimaryDiscipline { get; init; } = "";
        public int Revision { get; init; }
        public long Version { get; init; }
        public string Status { get; init; } = "";
        public Guid? ParentPlanId { get; init; }
        public Guid LineageId { get; init; }
        public DateTime? EndedAt { get; init; }
        public string? EndReason { get; init; }
        public string? EndNote { get; init; }
        public DateTime? ArchivedAt { get; init; }
        public DateTime CreatedAt { get; init; }
    }

    private sealed class WorkoutRow
    {
        public Guid Id { get; init; }
        public Guid PlanId { get; init; }
        public int Weekday { get; init; }
        public string Title { get; init; } = "";
        public int OrderIndex { get; init; }
        public int? RestBetweenExercisesSeconds { get; init; }
    }

    private sealed class ExerciseRow
    {
        public Guid Id { get; init; }
        public Guid PlannedWorkoutId { get; init; }
        public Guid ExerciseId { get; init; }
        public int OrderIndex { get; init; }
        public int SetCount { get; init; }
        public string TargetJson { get; init; } = "{}";
        public int RestSeconds { get; init; }
    }

    private sealed class ExerciseTypeRow
    {
        public Guid Id { get; init; }
        public string Type { get; init; } = "";
    }
}
