using System.Buffers.Text;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Cali.Domain.Plans;

namespace Cali.Application.Plans;

/// <summary>
/// Keyset position of the last returned plan revision. The page order is <c>(created_at, id)</c>:
/// both are immutable, so revisions created after a page was read appear on later pages and none are
/// skipped or repeated.
/// </summary>
public sealed record PlanCursor(DateTime CreatedAtUtc, Guid Id)
{
    private const int MaxEncodedLength = 512;

    /// <summary>Opaque cursor: base64url of the JSON array <c>[createdAt (ISO 8601 UTC), id]</c>.</summary>
    public string Encode() => Base64Url.EncodeToString(JsonSerializer.SerializeToUtf8Bytes(new[]
    {
        DateTime.SpecifyKind(CreatedAtUtc, DateTimeKind.Utc).ToString("O", CultureInfo.InvariantCulture),
        Id.ToString("D"),
    }));

    public static bool TryDecode(string? value, out PlanCursor? cursor)
    {
        cursor = null;
        if (string.IsNullOrEmpty(value) || value.Length > MaxEncodedLength)
        {
            return false;
        }

        try
        {
            var parts = JsonSerializer.Deserialize<string[]>(Base64Url.DecodeFromChars(value));
            if (parts is not [var createdAt, var id] || createdAt is null
                || !DateTime.TryParseExact(createdAt, "O", CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var timestamp)
                || timestamp.Kind != DateTimeKind.Utc
                || !Guid.TryParseExact(id, "D", out var guid))
            {
                return false;
            }

            cursor = new PlanCursor(timestamp, guid);
            return true;
        }
        catch (Exception e) when (e is FormatException or JsonException or DecoderFallbackException)
        {
            return false;
        }
    }
}

/// <summary>A listed revision with its keyset position.</summary>
public sealed record PlanListItem(TrainingPlan Plan, DateTime CreatedAtUtc);

public sealed record PlanPage(IReadOnlyList<TrainingPlan> Items, PlanCursor? NextCursor, bool HasMore);

public interface IPlanReader
{
    /// <summary>
    /// The user's non-deleted plan revisions ordered by <c>(created_at, id)</c> strictly after
    /// <paramref name="after"/>, with their live workouts and exercises. Always scoped to
    /// <paramref name="userId"/>.
    /// </summary>
    Task<IReadOnlyList<PlanListItem>> ListAsync(Guid userId, PlanCursor? after, int take, CancellationToken cancellationToken);

    /// <summary>Exercise type of each id that is a published catalog exercise; unknown ids are absent.</summary>
    Task<IReadOnlyDictionary<Guid, string>> GetPublishedExerciseTypesAsync(IReadOnlyCollection<Guid> exerciseIds, CancellationToken cancellationToken);
}

/// <summary>Use case behind <c>GET /v1/plans</c>.</summary>
public sealed class ListPlans(IPlanReader reader)
{
    public const int DefaultLimit = 50;
    public const int MaxLimit = 100;

    public async Task<PlanPage> ExecuteAsync(Guid userId, PlanCursor? after, int limit, CancellationToken cancellationToken)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 1);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(limit, MaxLimit);

        // One extra row tells whether another page exists without a COUNT query.
        var rows = await reader.ListAsync(userId, after, limit + 1, cancellationToken).ConfigureAwait(false);
        var hasMore = rows.Count > limit;
        var items = hasMore ? rows.Take(limit).ToArray() : rows;
        var next = hasMore ? new PlanCursor(items[^1].CreatedAtUtc, items[^1].Plan.Id) : null;
        return new PlanPage(items.Select(i => i.Plan).ToArray(), next, hasMore);
    }
}
