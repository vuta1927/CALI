using System.Buffers;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Cali.Domain.Catalog;
using Cali.Domain.Plans;

namespace Cali.Application.Plans;

/// <summary>A validated, normalized root plan ready to persist (revision 1, status <c>current</c>).</summary>
public sealed record NewPlan(
    Guid Id,
    string Title,
    string Kind,
    DateOnly? EventDate,
    string? EventName,
    string PrimaryDiscipline,
    IReadOnlyList<PlannedWorkout> Workouts);

/// <summary>
/// Plan, workout and exercise rules (OpenAPI bounds + ADR-020 cross-field business rules). docs/06: direct
/// create endpoints and sync push share these rules, so each entity has its own method that reports
/// field paths relative to the entity (<c>target.repMax</c>); callers pass a prefix for nested bodies.
/// Count limits (ADR-041) and id ownership are enforced by the database transaction, not here.
/// </summary>
public static class PlanValidator
{
    public const int MaxTitleLength = 120;
    public const int MaxEventNameLength = 120;

    internal const string Required = "Required.";

    private sealed record TargetField(string Name, bool Required, int Min, int Max, bool IsDecimal = false);

    // OpenAPI PlannedTarget: one variant per catalog exercise type, additionalProperties false.
    private static readonly Dictionary<string, TargetField[]> TargetFields = new(StringComparer.Ordinal)
    {
        ["static_hold"] = [new("holdSeconds", true, 1, 3600)],
        ["reps"] = [new("repMin", true, 1, 500), new("repMax", true, 1, 500)],
        ["timed_reps"] = [new("timeSeconds", true, 1, 3600)],
        ["interval"] = [new("workSeconds", true, 1, 3600), new("restSeconds", true, 1, 3600)],
        ["skill_attempt"] = [new("attempts", true, 1, 100)],
        ["distance"] = [new("distanceMeters", true, 1, 500000), new("durationSeconds", false, 1, 86400)],
        ["duration"] = [new("durationSeconds", true, 1, 86400)],
        ["load"] = [new("reps", true, 1, 500), new("loadKg", true, 0, 1000, IsDecimal: true)],
    };

    /// <summary>Target kinds this validator knows; must equal <see cref="ExerciseTypes.All"/>.</summary>
    public static IEnumerable<string> TargetKinds => TargetFields.Keys;

    /// <summary>Distinct catalog ids referenced by the request (for the published-type lookup).</summary>
    public static IReadOnlyCollection<Guid> ReferencedExerciseIds(CreatePlanInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        return (input.Workouts ?? [])
            .SelectMany(w => w?.Exercises ?? [])
            .Select(e => e?.ExerciseId)
            .OfType<Guid>()
            .Distinct()
            .ToArray();
    }

    /// <summary>
    /// Validates a whole <c>CreatePlanRequest</c>. <paramref name="publishedExerciseTypes"/> maps each
    /// published catalog id to its exercise type. Returns null when <paramref name="errors"/> got entries.
    /// </summary>
    public static NewPlan? ValidateCreate(CreatePlanInput input, IReadOnlyDictionary<Guid, string> publishedExerciseTypes, ValidationErrors errors)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(publishedExerciseTypes);
        ArgumentNullException.ThrowIfNull(errors);

        var ids = new HashSet<Guid>();
        RequireId(input.Id, "id", ids, errors);
        var plan = ValidatePlanFields(input.Title, input.Kind, input.EventDate, input.EventName, input.PrimaryDiscipline, prefix: "", errors);

        var workouts = new List<PlannedWorkout>();
        if (input.Workouts is null)
        {
            errors.Add("workouts", Required);
        }
        else
        {
            for (var w = 0; w < input.Workouts.Count; w++)
            {
                var prefix = $"workouts[{w}].";
                var workout = input.Workouts[w];
                if (workout is null)
                {
                    errors.Add($"workouts[{w}]", "Must be an object.");
                    continue;
                }

                RequireId(workout.Id, prefix + "id", ids, errors);
                var fields = ValidateWorkoutFields(workout.Weekday, workout.Title, workout.OrderIndex, prefix, errors);
                var restOk = workout.RestBetweenExercisesSeconds is null
                    || CheckInt(workout.RestBetweenExercisesSeconds, prefix + "restBetweenExercisesSeconds", 0, MaxRestBetweenExercisesSeconds, errors);
                var exercises = new List<PlannedExercise>();
                if (workout.Exercises is null)
                {
                    errors.Add(prefix + "exercises", Required);
                }
                else
                {
                    for (var e = 0; e < workout.Exercises.Count; e++)
                    {
                        var exercisePrefix = $"{prefix}exercises[{e}].";
                        var exercise = workout.Exercises[e];
                        if (exercise is null)
                        {
                            errors.Add($"{prefix}exercises[{e}]", "Must be an object.");
                            continue;
                        }

                        RequireId(exercise.Id, exercisePrefix + "id", ids, errors);
                        var valid = ValidateExercise(exercise, publishedExerciseTypes, exercisePrefix, errors);
                        if (valid is not null)
                        {
                            exercises.Add(valid);
                        }
                    }
                }

                if (fields is { } f && restOk && workout.Id is { } workoutId)
                {
                    workouts.Add(new PlannedWorkout(workoutId, f.Weekday, f.Title, f.OrderIndex, exercises, workout.RestBetweenExercisesSeconds));
                }
            }
        }

        if (errors.HasErrors || plan is not { } p || input.Id is not { } id)
        {
            return null;
        }

        return new NewPlan(id, p.Title, p.Kind, input.EventDate, input.EventName, p.Discipline, workouts);
    }

    /// <summary>
    /// <c>training_plan</c> scalar fields. Omitted <c>kind</c> = weekly, omitted <c>primaryDiscipline</c> =
    /// calisthenics (OpenAPI defaults); an event plan needs <c>eventDate</c> (ADR-035).
    /// </summary>
    public static (string Title, string Kind, string Discipline)? ValidatePlanFields(
        string? title, string? kind, DateOnly? eventDate, string? eventName, string? primaryDiscipline, string prefix, ValidationErrors errors)
    {
        ArgumentNullException.ThrowIfNull(errors);
        var ok = true;

        ok &= CheckText(title, prefix + "title", required: true, minLength: 1, MaxTitleLength, errors);
        var effectiveKind = kind ?? PlanKinds.Weekly;
        if (!PlanKinds.IsKnown(effectiveKind))
        {
            errors.Add(prefix + "kind", "Must be one of: weekly, event.");
            ok = false;
        }
        else if (effectiveKind == PlanKinds.Event && eventDate is null)
        {
            errors.Add(prefix + "eventDate", "Required when kind is event.");
            ok = false;
        }

        ok &= CheckText(eventName, prefix + "eventName", required: false, minLength: 1, MaxEventNameLength, errors);
        var discipline = primaryDiscipline ?? PrimaryDisciplines.Calisthenics;
        if (!PrimaryDisciplines.IsKnown(discipline))
        {
            errors.Add(prefix + "primaryDiscipline", "Must be one of: calisthenics, running, gym, mixed.");
            ok = false;
        }

        return ok ? (title!, effectiveKind, discipline) : null;
    }

    /// <summary><c>planned_workout</c> scalar fields; an omitted title is stored as "" (ADR-027).</summary>
    /// <summary>Upper bound of <c>planned_workouts.rest_between_exercises_seconds</c> (db/012, CON-011).</summary>
    public const int MaxRestBetweenExercisesSeconds = 3600;

    public static (int Weekday, string Title, int OrderIndex)? ValidateWorkoutFields(
        int? weekday, string? title, int? orderIndex, string prefix, ValidationErrors errors)
    {
        ArgumentNullException.ThrowIfNull(errors);
        var ok = CheckInt(weekday, prefix + "weekday", 1, 7, errors);
        ok &= CheckText(title, prefix + "title", required: false, minLength: 0, MaxTitleLength, errors);
        ok &= CheckInt(orderIndex, prefix + "orderIndex", 0, int.MaxValue, errors);
        return ok ? (weekday!.Value, title ?? "", orderIndex!.Value) : null;
    }

    /// <summary>
    /// <c>planned_exercise</c> fields: bounds, catalog reference (published only) and the target rules
    /// (kind = catalog exercise type, repMin &lt;= repMax, loadKg at most 2 decimals). Returns the exercise
    /// with a normalized target, or null when errors were added. The id is checked by the caller.
    /// </summary>
    public static PlannedExercise? ValidateExercise(
        PlannedExerciseInput input, IReadOnlyDictionary<Guid, string> publishedExerciseTypes, string prefix, ValidationErrors errors)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(publishedExerciseTypes);
        ArgumentNullException.ThrowIfNull(errors);

        var ok = input.Id is not null;
        string? exerciseType = null;
        if (input.ExerciseId is not { } exerciseId)
        {
            errors.Add(prefix + "exerciseId", Required);
            ok = false;
        }
        else if (!publishedExerciseTypes.TryGetValue(exerciseId, out exerciseType))
        {
            errors.Add(prefix + "exerciseId", "Must reference a published catalog exercise.");
            ok = false;
        }

        ok &= CheckInt(input.OrderIndex, prefix + "orderIndex", 0, int.MaxValue, errors);
        ok &= CheckInt(input.SetCount, prefix + "setCount", 1, 20, errors);
        ok &= CheckInt(input.RestSeconds, prefix + "restSeconds", 0, 3600, errors);
        var target = NormalizeTarget(input.Target, exerciseType, prefix, errors);

        return ok && target is { } t
            ? new PlannedExercise(input.Id!.Value, input.ExerciseId!.Value, input.OrderIndex!.Value, input.SetCount!.Value, t, input.RestSeconds!.Value)
            : null;
    }

    /// <summary>
    /// Validates a <c>PlannedTarget</c> and returns it normalized: <c>kind</c> first, then the variant's
    /// fields in schema order, <c>loadKg</c> without trailing zeros. <paramref name="exerciseType"/> is the
    /// catalog type of the referenced exercise, or null when unknown (only the shape is checked then).
    /// </summary>
    public static JsonElement? NormalizeTarget(JsonElement? target, string? exerciseType, string prefix, ValidationErrors errors)
    {
        ArgumentNullException.ThrowIfNull(errors);
        var path = prefix + "target";
        if (target is not { ValueKind: JsonValueKind.Object } value)
        {
            errors.Add(path, target is null ? Required : "Must be a PlannedTarget object.");
            return null;
        }

        if (!value.TryGetProperty("kind", out var kindElement) || kindElement.ValueKind != JsonValueKind.String
            || kindElement.GetString() is not { } kind || !TargetFields.TryGetValue(kind, out var fields))
        {
            errors.Add(path + ".kind", "Must be an exercise type: " + string.Join(", ", TargetFields.Keys) + ".");
            return null;
        }

        if (exerciseType is not null && kind != exerciseType)
        {
            errors.Add(path + ".kind", $"Must be '{exerciseType}', the type of the referenced catalog exercise.");
            return null;
        }

        var ok = true;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var member in value.EnumerateObject())
        {
            if (!seen.Add(member.Name))
            {
                errors.Add($"{path}.{member.Name}", "Duplicate property.");
                ok = false;
            }
            else if (member.Name != "kind" && !fields.Any(f => f.Name == member.Name))
            {
                errors.Add($"{path}.{member.Name}", $"Not allowed for kind '{kind}'.");
                ok = false;
            }
        }

        var integers = new Dictionary<string, long>(StringComparer.Ordinal);
        var decimals = new Dictionary<string, decimal>(StringComparer.Ordinal);
        foreach (var field in fields)
        {
            var fieldPath = $"{path}.{field.Name}";
            if (!value.TryGetProperty(field.Name, out var element))
            {
                if (field.Required)
                {
                    errors.Add(fieldPath, Required);
                    ok = false;
                }

                continue;
            }

            if (field.IsDecimal)
            {
                if (element.ValueKind != JsonValueKind.Number || !element.TryGetDecimal(out var number)
                    || number < field.Min || number > field.Max)
                {
                    errors.Add(fieldPath, $"Must be a number between {field.Min} and {field.Max}.");
                    ok = false;
                }
                else if (decimal.Round(number, 2) != number)
                {
                    errors.Add(fieldPath, "Must have at most 2 decimals.");
                    ok = false;
                }
                else
                {
                    decimals[field.Name] = DecimalText.Normalize(number);
                }
            }
            else if (element.ValueKind != JsonValueKind.Number || !element.TryGetInt64(out var integer)
                || integer < field.Min || integer > field.Max)
            {
                errors.Add(fieldPath, $"Must be an integer between {field.Min} and {field.Max}.");
                ok = false;
            }
            else
            {
                integers[field.Name] = integer;
            }
        }

        if (integers.TryGetValue("repMin", out var repMin) && integers.TryGetValue("repMax", out var repMax) && repMin > repMax)
        {
            errors.Add(path + ".repMax", "Must be greater than or equal to repMin.");
            ok = false;
        }

        if (!ok)
        {
            return null;
        }

        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteString("kind", kind);
            foreach (var field in fields)
            {
                if (integers.TryGetValue(field.Name, out var i))
                {
                    writer.WriteNumber(field.Name, i);
                }
                else if (decimals.TryGetValue(field.Name, out var d))
                {
                    writer.WriteNumber(field.Name, d);
                }
            }

            writer.WriteEndObject();
        }

        using var document = JsonDocument.Parse(buffer.WrittenMemory);
        return document.RootElement.Clone();
    }

    /// <summary>
    /// Length in Unicode code points (JSON Schema <c>maxLength</c>, PostgreSQL <c>length()</c>), or -1 when
    /// the text cannot be stored: an unpaired surrogate or U+0000 (rejected by PostgreSQL <c>text</c>).
    /// </summary>
    public static int TextLength(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var length = 0;
        var span = value.AsSpan();
        while (!span.IsEmpty)
        {
            if (Rune.DecodeFromUtf16(span, out var rune, out var consumed) != OperationStatus.Done || rune.Value == 0)
            {
                return -1;
            }

            length++;
            span = span[consumed..];
        }

        return length;
    }

    private static void RequireId(Guid? id, string field, HashSet<Guid> seen, ValidationErrors errors)
    {
        if (id is not { } value)
        {
            errors.Add(field, Required);
        }
        else if (!seen.Add(value))
        {
            errors.Add(field, "Duplicate id in this request.");
        }
    }

    internal static bool CheckInt(int? value, string field, int min, int max, ValidationErrors errors)
    {
        if (value is not { } v)
        {
            errors.Add(field, Required);
            return false;
        }

        if (v < min || v > max)
        {
            errors.Add(field, max == int.MaxValue
                ? string.Create(CultureInfo.InvariantCulture, $"Must be at least {min}.")
                : string.Create(CultureInfo.InvariantCulture, $"Must be between {min} and {max}."));
            return false;
        }

        return true;
    }

    internal static bool CheckText(string? value, string field, bool required, int minLength, int maxLength, ValidationErrors errors)
    {
        if (value is null)
        {
            if (required)
            {
                errors.Add(field, Required);
            }

            return !required;
        }

        var length = TextLength(value);
        if (length < 0)
        {
            errors.Add(field, "Must be valid Unicode text without U+0000.");
            return false;
        }

        if (length < minLength || length > maxLength)
        {
            errors.Add(field, string.Create(CultureInfo.InvariantCulture, $"Length must be between {minLength} and {maxLength} characters."));
            return false;
        }

        return true;
    }
}
