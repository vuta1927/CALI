using System.Buffers.Text;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Cali.Domain.Catalog;

namespace Cali.Application.Catalog;

/// <summary>Optional filters of <c>GET /v1/exercises</c>; null means "not filtered".</summary>
public sealed record ExerciseFilter(string? Query, string? Type, string? Equipment);

/// <summary>
/// Keyset position of the last returned exercise. The page order is <c>(slug, id)</c>, so rows inserted
/// before the position are never returned again and rows after it are not skipped.
/// </summary>
public sealed partial record ExerciseCursor(string Slug, Guid Id)
{
    private const int MaxEncodedLength = 512;

    /// <summary>Opaque cursor: base64url of the JSON array <c>[slug, id]</c>.</summary>
    public string Encode() => Base64Url.EncodeToString(JsonSerializer.SerializeToUtf8Bytes(new[] { Slug, Id.ToString("D") }));

    public static bool TryDecode(string? value, out ExerciseCursor? cursor)
    {
        cursor = null;
        if (string.IsNullOrEmpty(value) || value.Length > MaxEncodedLength)
        {
            return false;
        }

        try
        {
            var parts = JsonSerializer.Deserialize<string[]>(Base64Url.DecodeFromChars(value));
            if (parts is not [var slug, var id] || slug is null || !SlugPattern().IsMatch(slug)
                || !Guid.TryParseExact(id, "D", out var guid))
            {
                return false;
            }

            cursor = new ExerciseCursor(slug, guid);
            return true;
        }
        catch (Exception e) when (e is FormatException or JsonException or DecoderFallbackException)
        {
            return false;
        }
    }

    [GeneratedRegex("^[a-z0-9]+(-[a-z0-9]+)*$")]
    private static partial Regex SlugPattern();
}

public sealed record ExercisePage(IReadOnlyList<CatalogExercise> Items, ExerciseCursor? NextCursor, bool HasMore);

public interface IExerciseCatalogReader
{
    /// <summary>Published exercises ordered by <c>(slug, id)</c> strictly after <paramref name="after"/>.</summary>
    Task<IReadOnlyList<CatalogExercise>> ListAsync(ExerciseFilter filter, ExerciseCursor? after, int take, CancellationToken cancellationToken);

    /// <summary>The published exercise with this id, or null.</summary>
    Task<CatalogExercise?> FindAsync(Guid id, CancellationToken cancellationToken);
}

/// <summary>Use case behind <c>GET /v1/exercises</c>.</summary>
public sealed class ListExercises(IExerciseCatalogReader reader)
{
    public const int DefaultLimit = 50;
    public const int MaxLimit = 100;

    public async Task<ExercisePage> ExecuteAsync(ExerciseFilter filter, ExerciseCursor? after, int limit, CancellationToken cancellationToken)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 1);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(limit, MaxLimit);

        // One extra row tells whether another page exists without a COUNT query.
        var rows = await reader.ListAsync(filter, after, limit + 1, cancellationToken).ConfigureAwait(false);
        var hasMore = rows.Count > limit;
        var items = hasMore ? rows.Take(limit).ToArray() : rows;
        var next = hasMore ? new ExerciseCursor(items[^1].Slug, items[^1].Id) : null;
        return new ExercisePage(items, next, hasMore);
    }
}

/// <summary>Use case behind <c>GET /v1/exercises/{id}</c>.</summary>
public sealed class GetExercise(IExerciseCatalogReader reader)
{
    public Task<CatalogExercise?> ExecuteAsync(Guid id, CancellationToken cancellationToken) => reader.FindAsync(id, cancellationToken);
}
