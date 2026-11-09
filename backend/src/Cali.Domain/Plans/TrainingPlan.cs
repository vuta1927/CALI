using System.Text.Json;

namespace Cali.Domain.Plans;

/// <summary>Values of <c>training_plans.status</c>: the REVISION status (ADR-036, ADR-056).</summary>
public static class PlanRevisionStatus
{
    public const string Current = "current";
    public const string Superseded = "superseded";
}

/// <summary>Values of <c>training_plans.kind</c> (ADR-035).</summary>
public static class PlanKinds
{
    public const string Weekly = "weekly";
    public const string Event = "event";

    public static bool IsKnown(string? value) => value is Weekly or Event;
}

/// <summary>Values of <c>training_plans.primary_discipline</c> (OpenAPI <c>PrimaryDiscipline</c>).</summary>
public static class PrimaryDisciplines
{
    public const string Calisthenics = "calisthenics";

    public static bool IsKnown(string? value) => value is Calisthenics or "running" or "gym" or "mixed";
}

/// <summary>
/// One plan revision with its live workouts and exercises. Property names serialize (camelCase) to the
/// OpenAPI <c>TrainingPlan</c> schema, so the same record is the HTTP response and the stored
/// idempotent replay body.
/// </summary>
public sealed record TrainingPlan(
    Guid Id,
    string Title,
    string Kind,
    DateOnly? EventDate,
    string? EventName,
    string PrimaryDiscipline,
    IReadOnlyList<PlannedWorkout> Workouts,
    int Revision,
    long Version,
    string Status,
    Guid? ParentPlanId,
    Guid LineageId,
    DateTimeOffset? EndedAt,
    string? EndReason,
    string? EndNote,
    DateTimeOffset? ArchivedAt);

/// <summary>OpenAPI <c>PlannedWorkout</c>; <c>title</c> is "" when the client omitted it (ADR-027).</summary>
public sealed record PlannedWorkout(Guid Id, int Weekday, string Title, int OrderIndex, IReadOnlyList<PlannedExercise> Exercises);

/// <summary>OpenAPI <c>PlannedExercise</c>; <paramref name="Target"/> is a <c>PlannedTarget</c> object.</summary>
public sealed record PlannedExercise(Guid Id, Guid ExerciseId, int OrderIndex, int SetCount, JsonElement Target, int RestSeconds);
