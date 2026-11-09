using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Cali.Domain.Catalog;

namespace Cali.Application.Sync;

/// <summary>
/// Read-only server data a push validates against, loaded before the write transaction: published
/// catalog exercise types, criteria config documents by version, and indicator definitions. All three
/// are server-owned and never change inside a user's transaction (criteria versions are immutable).
/// </summary>
public sealed record SyncLookups(
    IReadOnlyDictionary<Guid, string> PublishedExerciseTypes,
    IReadOnlyDictionary<int, string> CriteriaDocuments,
    IReadOnlyDictionary<string, IndicatorDefinition> Indicators);

/// <summary>Per-set criteria values (CON-008, ADR-067).</summary>
internal static partial class CriteriaRules
{
    private static readonly string[] ReservedKeys = ["rpe", "pain", "holdSec", "reps", "loadKg"];

    /// <summary>The schema part of <c>criteria_values</c>: key pattern, reserved keys and value shapes.</summary>
    public static string? CheckShape(JsonElement criteria)
    {
        if (criteria.ValueKind != JsonValueKind.Object)
        {
            return "Must be an object.";
        }

        var count = 0;
        var keys = new HashSet<string>(StringComparer.Ordinal);
        foreach (var member in criteria.EnumerateObject())
        {
            count++;
            if (!keys.Add(member.Name))
            {
                return "Duplicate criterion id.";
            }

            if (!KeyPattern().IsMatch(member.Name) || ReservedKeys.Contains(member.Name, StringComparer.Ordinal))
            {
                return "Criterion ids are lowercase-first identifiers and never rpe, pain, holdSec, reps or loadKg.";
            }

            if (!IsValueShape(member.Value))
            {
                return "Values are a token, a number between -100000 and 100000, a boolean or up to 10 unique tokens.";
            }
        }

        return count > 20 ? "Must have at most 20 criteria." : null;
    }

    /// <summary>The business part (ADR-067): every key is an enabled criterion of the version and the value matches its type.</summary>
    public static string? CheckAgainstDocument(JsonElement criteria, string documentJson)
    {
        using var document = JsonDocument.Parse(documentJson);
        var definitions = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        if (document.RootElement.TryGetProperty("criteria", out var list) && list.ValueKind == JsonValueKind.Array)
        {
            foreach (var definition in list.EnumerateArray())
            {
                if (definition.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String)
                {
                    definitions[id.GetString()!] = definition;
                }
            }
        }

        foreach (var member in criteria.EnumerateObject())
        {
            if (!definitions.TryGetValue(member.Name, out var definition)
                || !definition.TryGetProperty("enabled", out var enabled) || enabled.ValueKind != JsonValueKind.True)
            {
                return string.Create(CultureInfo.InvariantCulture, $"'{member.Name}' is not an enabled criterion of this criteria version.");
            }

            if (!MatchesDefinition(member.Value, definition))
            {
                return string.Create(CultureInfo.InvariantCulture, $"The value of '{member.Name}' does not match the criterion type or options.");
            }
        }

        return null;
    }

    private static bool IsValueShape(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => TokenPattern().IsMatch(value.GetString()!),
        JsonValueKind.Number => value.TryGetDecimal(out var n) && n >= -100000 && n <= 100000,
        JsonValueKind.True or JsonValueKind.False => true,
        JsonValueKind.Array => value.GetArrayLength() <= 10
            && value.EnumerateArray().All(i => i.ValueKind == JsonValueKind.String && TokenPattern().IsMatch(i.GetString()!))
            && value.EnumerateArray().Select(i => i.GetString()).Distinct(StringComparer.Ordinal).Count() == value.GetArrayLength(),
        _ => false,
    };

    private static bool MatchesDefinition(JsonElement value, JsonElement definition)
    {
        var type = definition.TryGetProperty("type", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() : null;
        switch (type)
        {
            case "choice":
                return value.ValueKind == JsonValueKind.String && Options(definition).Contains(value.GetString()!);
            case "chips":
                var options = Options(definition);
                return value.ValueKind == JsonValueKind.Array && value.EnumerateArray().All(i => options.Contains(i.GetString()!));
            case "toggle":
                return value.ValueKind is JsonValueKind.True or JsonValueKind.False;
            case "scale":
            case "number":
                if (value.ValueKind != JsonValueKind.Number || !value.TryGetDecimal(out var number))
                {
                    return false;
                }

                return (!definition.TryGetProperty("min", out var min) || !min.TryGetDecimal(out var lo) || number >= lo)
                    && (!definition.TryGetProperty("max", out var max) || !max.TryGetDecimal(out var hi) || number <= hi);
            default:
                return false;
        }
    }

    private static HashSet<string> Options(JsonElement definition)
    {
        var options = new HashSet<string>(StringComparer.Ordinal);
        if (definition.TryGetProperty("options", out var list) && list.ValueKind == JsonValueKind.Array)
        {
            foreach (var option in list.EnumerateArray())
            {
                if (option.TryGetProperty("v", out var v) && v.ValueKind == JsonValueKind.String)
                {
                    options.Add(v.GetString()!);
                }
            }
        }

        return options;
    }

    [GeneratedRegex("^[a-z][a-zA-Z0-9_]{0,31}$", RegexOptions.CultureInvariant)]
    private static partial Regex KeyPattern();

    [GeneratedRegex("^[a-z][a-z0-9_]{0,31}$", RegexOptions.CultureInvariant)]
    private static partial Regex TokenPattern();
}

/// <summary>Goal indicator rules (CON-005, docs/18 §6.1).</summary>
internal static class IndicatorRules
{
    private static readonly string[] ExerciseKinds = ["performance", "volume", "milestone"];

    /// <summary>Returns the failing field and message, or null when the indicator/exercise pair is valid.</summary>
    public static (string Field, string Message)? Check(string indicatorId, Guid? exerciseId, SyncLookups lookups)
    {
        if (!lookups.Indicators.TryGetValue(indicatorId, out var indicator) || !indicator.Enabled)
        {
            return ("indicatorId", "Must be an enabled indicator.");
        }

        if (exerciseId is null)
        {
            return ExerciseKinds.Contains(indicator.Kind, StringComparer.Ordinal)
                ? ("exerciseId", "This indicator needs an exercise.")
                : null;
        }

        if (!lookups.PublishedExerciseTypes.TryGetValue(exerciseId.Value, out var exerciseType))
        {
            return ("exerciseId", "Must be a published catalog exercise.");
        }

        return indicator.MeasurementTypes.Count > 0
            && !indicator.MeasurementTypes.Contains(MeasurementTypes.ForExerciseType(exerciseType), StringComparer.Ordinal)
            ? ("exerciseId", "The exercise measurement type is not supported by this indicator.")
            : null;
    }
}
