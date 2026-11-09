using System.Buffers;
using System.Security.Cryptography;
using System.Text.Json;

namespace Cali.Application.Plans;

/// <summary>
/// ADR-068: fingerprint of an idempotent request body. SHA-256 (lowercase hex) of a canonical form of
/// the JSON: object members sorted by name (ordinal, stable for duplicates), no whitespace, numbers
/// that fit <see cref="decimal"/> written with their smallest scale, other numbers kept as written.
/// It only needs to be deterministic for the same server build: it compares a retry with the request
/// that stored the result, so whitespace or member order changes in a retry still replay.
/// </summary>
public static class PlanRequestHash
{
    public static string Compute(JsonElement body)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            Write(writer, body);
        }

        return Convert.ToHexStringLower(SHA256.HashData(buffer.WrittenSpan));
    }

    private static void Write(Utf8JsonWriter writer, JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var member in element.EnumerateObject().OrderBy(m => m.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(member.Name);
                    Write(writer, member.Value);
                }

                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in element.EnumerateArray())
                {
                    Write(writer, item);
                }

                writer.WriteEndArray();
                break;
            case JsonValueKind.String:
                writer.WriteStringValue(element.GetString());
                break;
            case JsonValueKind.Number:
                if (element.TryGetDecimal(out var number))
                {
                    writer.WriteNumberValue(DecimalText.Normalize(number));
                }
                else
                {
                    writer.WriteRawValue(element.GetRawText(), skipInputValidation: true);
                }

                break;
            case JsonValueKind.True:
                writer.WriteBooleanValue(true);
                break;
            case JsonValueKind.False:
                writer.WriteBooleanValue(false);
                break;
            default:
                writer.WriteNullValue();
                break;
        }
    }
}
