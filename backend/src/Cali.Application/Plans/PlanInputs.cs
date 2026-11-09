using System.Text.Json;

namespace Cali.Application.Plans;

/// <summary>
/// OpenAPI <c>CreatePlanRequest</c> as received. Every member is nullable so a missing value becomes a
/// field error from <see cref="PlanValidator"/> instead of a deserialization failure. Unknown JSON
/// members are ignored (the schema does not set <c>additionalProperties: false</c>).
/// </summary>
public sealed record CreatePlanInput(
    Guid? Id,
    string? Title,
    string? Kind,
    DateOnly? EventDate,
    string? EventName,
    string? PrimaryDiscipline,
    IReadOnlyList<PlannedWorkoutInput?>? Workouts);

/// <summary>OpenAPI <c>PlannedWorkout</c> as received.</summary>
public sealed record PlannedWorkoutInput(
    Guid? Id,
    int? Weekday,
    string? Title,
    int? OrderIndex,
    IReadOnlyList<PlannedExerciseInput?>? Exercises);

/// <summary>
/// OpenAPI <c>PlannedExercise</c> (and the <c>planned_exercise_payload</c> fields shared with sync push)
/// as received. <see cref="Target"/> stays raw JSON until <see cref="PlanValidator"/> normalizes it.
/// </summary>
public sealed record PlannedExerciseInput(
    Guid? Id,
    Guid? ExerciseId,
    int? OrderIndex,
    int? SetCount,
    JsonElement? Target,
    int? RestSeconds);
