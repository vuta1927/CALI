using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.OpenApi;

namespace Cali.ContractTests;

/// <summary>
/// Validates a JSON value against an OpenAPI 3.1 schema: $ref (resolved by Microsoft.OpenApi), allOf, oneOf,
/// type (incl. null), format (uuid, date-time, date, uri), enum, pattern, min/max length, maxItems,
/// required, nested properties/items and <c>additionalProperties: false</c>. Numeric bounds and
/// uniqueItems are not checked.
/// </summary>
internal static class SchemaValidator
{
    public static void ShouldMatch(JsonElement value, IOpenApiSchema schema, string path)
    {
        var errors = new List<string>();
        Validate(value, schema, path, errors);
        errors.ShouldBeEmpty(string.Join(Environment.NewLine, errors));
    }

    public static void Validate(JsonElement value, IOpenApiSchema schema, string path, List<string> errors)
    {
        foreach (var part in schema.AllOf ?? [])
        {
            Validate(value, part, path, errors);
        }

        if (schema.OneOf is { Count: > 0 } oneOf)
        {
            var matches = oneOf.Count(option =>
            {
                var optionErrors = new List<string>();
                Validate(value, option, path, optionErrors);
                return optionErrors.Count == 0;
            });
            if (matches != 1)
            {
                errors.Add($"{path}: matches {matches} oneOf options (expected exactly 1)");
            }
        }

        if (schema.Enum is { Count: > 0 } allowed)
        {
            var actual = JsonNode.Parse(value.GetRawText());
            // Microsoft.OpenApi loads a YAML `null` enum member as a sentinel node, not as a JSON null.
            if (!allowed.Any(a => a is null || a.IsJsonNullSentinel() ? actual is null : JsonNode.DeepEquals(a, actual)))
            {
                errors.Add($"{path}: '{value}' is not one of the enum values");
            }
        }

        if (schema.Type is not { } type)
        {
            return; // composition-only or unconstrained schema
        }

        var typeOk = value.ValueKind switch
        {
            JsonValueKind.Null => type.HasFlag(JsonSchemaType.Null),
            JsonValueKind.String => type.HasFlag(JsonSchemaType.String),
            JsonValueKind.Number => type.HasFlag(JsonSchemaType.Number) || (type.HasFlag(JsonSchemaType.Integer) && value.TryGetInt64(out _)),
            JsonValueKind.True or JsonValueKind.False => type.HasFlag(JsonSchemaType.Boolean),
            JsonValueKind.Object => type.HasFlag(JsonSchemaType.Object),
            JsonValueKind.Array => type.HasFlag(JsonSchemaType.Array),
            _ => false,
        };
        if (!typeOk)
        {
            errors.Add($"{path}: JSON {value.ValueKind} '{value}' does not match spec type {type}");
            return;
        }

        switch (value.ValueKind)
        {
            case JsonValueKind.String:
                ValidateString(value.GetString()!, schema, path, errors);
                break;
            case JsonValueKind.Object:
                ValidateObject(value, schema, path, errors);
                break;
            case JsonValueKind.Array:
                ValidateArray(value, schema, path, errors);
                break;
        }
    }

    private static void ValidateString(string value, IOpenApiSchema schema, string path, List<string> errors)
    {
        if (!FormatOk(value, schema.Format))
        {
            errors.Add($"{path}: '{value}' is not a valid {schema.Format}");
        }

        if (schema.Pattern is { } pattern && !Regex.IsMatch(value, pattern, RegexOptions.None, TimeSpan.FromSeconds(1)))
        {
            errors.Add($"{path}: '{value}' does not match pattern {pattern}");
        }

        if (schema.MaxLength is { } max && value.Length > max)
        {
            errors.Add($"{path}: length {value.Length} > maxLength {max}");
        }

        if (schema.MinLength is { } min && value.Length < min)
        {
            errors.Add($"{path}: length {value.Length} < minLength {min}");
        }
    }

    private static void ValidateObject(JsonElement value, IOpenApiSchema schema, string path, List<string> errors)
    {
        foreach (var required in schema.Required ?? new HashSet<string>())
        {
            if (!value.TryGetProperty(required, out _))
            {
                errors.Add($"{path}.{required} is required by the spec");
            }
        }

        var properties = schema.Properties ?? new Dictionary<string, IOpenApiSchema>();
        foreach (var member in value.EnumerateObject())
        {
            if (properties.TryGetValue(member.Name, out var propertySchema))
            {
                Validate(member.Value, propertySchema, $"{path}.{member.Name}", errors);
            }
            else if (!schema.AdditionalPropertiesAllowed)
            {
                errors.Add($"{path}.{member.Name} is not declared and additionalProperties is false");
            }
        }
    }

    private static void ValidateArray(JsonElement value, IOpenApiSchema schema, string path, List<string> errors)
    {
        var length = value.GetArrayLength();
        if (schema.MaxItems is { } max && length > max)
        {
            errors.Add($"{path}: {length} items > maxItems {max}");
        }

        if (schema.Items is { } items)
        {
            var index = 0;
            foreach (var item in value.EnumerateArray())
            {
                Validate(item, items, $"{path}[{index++}]", errors);
            }
        }
    }

    private static bool FormatOk(string value, string? format) => format switch
    {
        "uuid" => Guid.TryParseExact(value, "D", out _),
        "date-time" => value.Contains('T', StringComparison.Ordinal)
            && DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out _),
        "date" => DateOnly.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _),
        "uri" => Uri.TryCreate(value, UriKind.Absolute, out _),
        _ => true,
    };
}
