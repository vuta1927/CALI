using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Cali.Application.Plans;

namespace Cali.Application.Sync;

/// <summary>A column value sent to PostgreSQL as invariant text and cast in SQL (<c>CAST(@p AS type)</c>).</summary>
public sealed record SqlColumn(string Name, string SqlType, string? Value);

/// <summary>
/// Reads one closed payload object (contracts/entity-payloads.schema.json, ADR-030). Every getter checks
/// the JSON type and bounds, records the first problem per field in <see cref="Errors"/>, binds the
/// stored value to a column and writes the normalized value into <see cref="Change"/> (the change-log
/// payload). An omitted nullable field is stored and echoed as null, so an upsert is always the whole
/// entity state. <see cref="Finish"/> reports members no getter asked for.
/// </summary>
internal sealed partial class PayloadReader
{
    private readonly Dictionary<string, JsonElement> members = new(StringComparer.Ordinal);
    private readonly HashSet<string> known = new(StringComparer.Ordinal);
    private readonly List<SqlColumn> columns = [];

    public PayloadReader(JsonElement payload, ValidationErrors errors)
    {
        Errors = errors;
        foreach (var member in payload.EnumerateObject())
        {
            if (!members.TryAdd(member.Name, member.Value))
            {
                Errors.Add(member.Name, "Duplicate property.");
            }
        }
    }

    public ValidationErrors Errors { get; }

    public JsonObject Change { get; } = [];

    public IReadOnlyList<SqlColumn> Columns => columns;

    public bool Has(string field) => members.ContainsKey(field);

    public void Bind(string column, string sqlType, string? value) => columns.Add(new SqlColumn(column, sqlType, value));

    public JsonElement? Raw(string field)
    {
        known.Add(field);
        return members.TryGetValue(field, out var value) ? value : null;
    }

    public Guid? Uuid(string field, string? column, bool required, bool nullable = false)
    {
        if (!TryGet(field, required, nullable, out var element))
        {
            BindNull(field, column, "uuid", nullable);
            return null;
        }

        if (element.ValueKind != JsonValueKind.String || !TryParseUuid(element.GetString()!, out var id))
        {
            Errors.Add(field, "Must be a UUID string.");
            return null;
        }

        var text = id.ToString("D");
        Store(field, column, "uuid", text, JsonValue.Create(text));
        return id;
    }

    public string? Text(string field, string? column, bool required, int minLength, int maxLength, bool nullable = false, string? defaultValue = null)
    {
        if (!TryGet(field, required, nullable, out var element))
        {
            if (defaultValue is not null && !Has(field))
            {
                Store(field, column, "text", defaultValue, JsonValue.Create(defaultValue));
                return defaultValue;
            }

            BindNull(field, column, "text", nullable);
            return null;
        }

        if (element.ValueKind != JsonValueKind.String)
        {
            Errors.Add(field, "Must be a string.");
            return null;
        }

        var value = element.GetString()!;
        if (!PlanValidator.CheckText(value, field, required: true, minLength, maxLength, Errors))
        {
            return null;
        }

        Store(field, column, "text", value, JsonValue.Create(value));
        return value;
    }

    public string? Enum(string field, string? column, bool required, IReadOnlyCollection<string> values, bool nullable = false, string? defaultValue = null)
    {
        if (!TryGet(field, required, nullable, out var element))
        {
            if (defaultValue is not null && !Has(field))
            {
                Store(field, column, "text", defaultValue, JsonValue.Create(defaultValue));
                return defaultValue;
            }

            BindNull(field, column, "text", nullable);
            return null;
        }

        if (element.ValueKind != JsonValueKind.String || !values.Contains(element.GetString()!, StringComparer.Ordinal))
        {
            Errors.Add(field, "Must be one of: " + string.Join(", ", values) + ".");
            return null;
        }

        var value = element.GetString()!;
        Store(field, column, "text", value, JsonValue.Create(value));
        return value;
    }

    public long? Integer(string field, string? column, bool required, long min, long max, bool nullable = false, long? defaultValue = null, string sqlType = "integer")
    {
        if (!TryGet(field, required, nullable, out var element))
        {
            if (defaultValue is { } d && !Has(field))
            {
                Store(field, column, sqlType, d.ToString(CultureInfo.InvariantCulture), JsonValue.Create(d));
                return d;
            }

            BindNull(field, column, sqlType, nullable);
            return null;
        }

        if (element.ValueKind != JsonValueKind.Number || !element.TryGetDecimal(out var number)
            || decimal.Truncate(number) != number || number < min || number > max)
        {
            Errors.Add(field, max == long.MaxValue
                ? string.Create(CultureInfo.InvariantCulture, $"Must be an integer of at least {min}.")
                : string.Create(CultureInfo.InvariantCulture, $"Must be an integer between {min} and {max}."));
            return null;
        }

        var value = (long)number;
        Store(field, column, sqlType, value.ToString(CultureInfo.InvariantCulture), JsonValue.Create(value));
        return value;
    }

    /// <summary>A decimal number; <paramref name="maxDecimals"/> extra precision is rejected, never rounded (ADR-062).</summary>
    public decimal? Number(string field, string? column, bool required, decimal min, decimal max, int? maxDecimals, bool nullable = false)
    {
        if (!TryGet(field, required, nullable, out var element))
        {
            BindNull(field, column, "numeric", nullable);
            return null;
        }

        if (!TryReadNumber(element, min, max, out var value))
        {
            Errors.Add(field, string.Create(CultureInfo.InvariantCulture, $"Must be a number between {min} and {max}."));
            return null;
        }

        if (maxDecimals is { } places && decimal.Round(value, places) != value)
        {
            Errors.Add(field, string.Create(CultureInfo.InvariantCulture, $"Must have at most {places} decimals."));
            return null;
        }

        Store(field, column, "numeric", value.ToString(CultureInfo.InvariantCulture), JsonValue.Create(value));
        return value;
    }

    public bool? Bool(string field, string? column, bool required, bool? defaultValue = null)
    {
        if (!TryGet(field, required, nullable: false, out var element))
        {
            if (defaultValue is { } d && !Has(field))
            {
                Store(field, column, "boolean", d ? "true" : "false", JsonValue.Create(d));
                return d;
            }

            return null;
        }

        if (element.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            Errors.Add(field, "Must be a boolean.");
            return null;
        }

        var value = element.GetBoolean();
        Store(field, column, "boolean", value ? "true" : "false", JsonValue.Create(value));
        return value;
    }

    /// <summary>RFC 3339 date-time; stored and echoed in UTC with microsecond precision (PostgreSQL timestamptz).</summary>
    public DateTimeOffset? DateTime(string field, string? column, bool required, bool nullable = false)
    {
        if (!TryGet(field, required, nullable, out var element))
        {
            BindNull(field, column, "timestamptz", nullable);
            return null;
        }

        if (element.ValueKind != JsonValueKind.String || !TryParseDateTime(element.GetString()!, out var value))
        {
            Errors.Add(field, "Must be an RFC 3339 date-time.");
            return null;
        }

        var text = FormatDateTime(value);
        Store(field, column, "timestamptz", text, JsonValue.Create(text));
        return value;
    }

    public DateOnly? Date(string field, string? column, bool required, bool nullable = false)
    {
        if (!TryGet(field, required, nullable, out var element))
        {
            BindNull(field, column, "date", nullable);
            return null;
        }

        if (element.ValueKind != JsonValueKind.String
            || !DateOnly.TryParseExact(element.GetString(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var value))
        {
            Errors.Add(field, "Must be a date (YYYY-MM-DD).");
            return null;
        }

        var text = value.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        Store(field, column, "date", text, JsonValue.Create(text));
        return value;
    }

    /// <summary>Reports members that no getter read (closed payloads, ADR-030).</summary>
    public void Finish()
    {
        foreach (var name in members.Keys.Where(n => !known.Contains(n)))
        {
            Errors.Add(name, "Unknown property.");
        }
    }

    public static bool TryParseUuid(string text, out Guid id) =>
        Guid.TryParseExact(text, "D", out id);

    public static bool TryParseDateTime(string text, out DateTimeOffset value)
    {
        value = default;
        var match = DateTimePattern().Match(text);
        if (!match.Success)
        {
            return false;
        }

        // .NET parses at most 7 fractional digits; PostgreSQL keeps 6, so the rest never matters.
        var fraction = match.Groups["fraction"];
        var normalized = fraction.Success && fraction.Length > 8
            ? string.Concat(text.AsSpan(0, fraction.Index + 8), text.AsSpan(fraction.Index + fraction.Length))
            : text;
        if (!DateTimeOffset.TryParse(normalized, CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed))
        {
            return false;
        }

        var utc = parsed.ToUniversalTime();
        value = new DateTimeOffset(utc.Ticks - (utc.Ticks % 10), TimeSpan.Zero);
        return true;
    }

    public static string FormatDateTime(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'", CultureInfo.InvariantCulture);

    internal static bool TryReadNumber(JsonElement element, decimal min, decimal max, out decimal value)
    {
        value = 0;
        if (element.ValueKind != JsonValueKind.Number || !element.TryGetDecimal(out var number) || number < min || number > max)
        {
            return false;
        }

        value = DecimalText.Normalize(number);
        return true;
    }

    private bool TryGet(string field, bool required, bool nullable, out JsonElement element)
    {
        known.Add(field);
        if (!members.TryGetValue(field, out element))
        {
            if (required)
            {
                Errors.Add(field, PlanValidator.Required);
            }

            return false;
        }

        if (element.ValueKind == JsonValueKind.Null)
        {
            if (!nullable)
            {
                Errors.Add(field, "Must not be null.");
            }

            return false;
        }

        return true;
    }

    private void BindNull(string field, string? column, string sqlType, bool nullable)
    {
        if (!nullable)
        {
            return;
        }

        if (column is not null)
        {
            columns.Add(new SqlColumn(column, sqlType, null));
        }

        Change[field] = null;
    }

    private void Store(string field, string? column, string sqlType, string value, JsonNode node)
    {
        if (column is not null)
        {
            columns.Add(new SqlColumn(column, sqlType, value));
        }

        Change[field] = node;
    }

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?<fraction>\.\d+)?([Zz]|[+-]\d{2}:\d{2})$", RegexOptions.CultureInvariant)]
    private static partial Regex DateTimePattern();
}
