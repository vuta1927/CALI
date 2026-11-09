namespace Cali.Domain.Catalog;

/// <summary>A published exercise of the server catalog (<c>exercise_catalog</c>) with its public, reviewed media.</summary>
public sealed record CatalogExercise(
    Guid Id,
    string Slug,
    string Name,
    string Type,
    string Discipline,
    IReadOnlyList<string> FocusTags,
    IReadOnlyList<string> Equipment,
    IReadOnlyList<string> Cues,
    int CatalogVersion,
    IReadOnlyList<CatalogMedia> Media)
{
    /// <summary>Derived from <see cref="Type"/> (ADR-060); never stored.</summary>
    public string MeasurementType => MeasurementTypes.ForExerciseType(Type);
}

/// <summary>Media metadata (<c>exercise_media</c>). <see cref="StorageKey"/> is server-internal and never sent as-is.</summary>
public sealed record CatalogMedia(
    Guid Id,
    string Kind,
    int ContentVersion,
    string StorageKey,
    string MimeType,
    string Sha256,
    long? SizeBytes,
    long? DurationMs,
    string License,
    string? Attribution);

/// <summary>Catalog exercise types (OpenAPI <c>ExerciseType</c>, db/006 check constraint).</summary>
public static class ExerciseTypes
{
    public static IReadOnlySet<string> All { get; } = new HashSet<string>(StringComparer.Ordinal)
    {
        "static_hold", "reps", "timed_reps", "interval", "skill_attempt", "distance", "duration", "load",
    };

    public static bool IsKnown(string? type) => type is not null && All.Contains(type);
}

/// <summary>ADR-060: the measurement type is a fixed function of the exercise type.</summary>
public static class MeasurementTypes
{
    public static string ForExerciseType(string exerciseType) => exerciseType switch
    {
        "static_hold" => "hold",
        "reps" or "timed_reps" or "skill_attempt" => "reps",
        "interval" or "duration" => "duration",
        "distance" => "distance",
        "load" => "load",
        _ => throw new ArgumentOutOfRangeException(nameof(exerciseType), exerciseType, "Unknown exercise type."),
    };
}
