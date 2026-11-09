using System.Text.Json;
using Cali.Application.Catalog;
using Cali.Domain.Catalog;
using Dapper;
using Npgsql;

namespace Cali.Infrastructure.Persistence;

/// <summary>Reads published exercises (<c>is_published</c>) and their public, reviewed media.</summary>
public sealed class ExerciseCatalogReader(NpgsqlDataSource dataSource) : IExerciseCatalogReader
{
    private const string Columns = """
        id AS Id, slug AS Slug, name AS Name, exercise_type AS Type, discipline AS Discipline,
        focus_tags::text AS FocusTagsJson, equipment::text AS EquipmentJson, cues::text AS CuesJson,
        catalog_version AS CatalogVersion
        """;

    // Keyset pagination on (slug, id): slug is unique, id breaks ties defensively.
    private const string ListSql = $"""
        SELECT {Columns}
        FROM exercise_catalog
        WHERE is_published
          AND (CAST(@type AS text) IS NULL OR exercise_type = @type)
          AND (CAST(@equipment AS text) IS NULL OR equipment @> jsonb_build_array(CAST(@equipment AS text)))
          AND (CAST(@pattern AS text) IS NULL OR name ILIKE @pattern ESCAPE '\' OR slug ILIKE @pattern ESCAPE '\')
          AND (CAST(@afterSlug AS text) IS NULL OR (slug, id) > (CAST(@afterSlug AS text), CAST(@afterId AS uuid)))
        ORDER BY slug, id
        LIMIT @take
        """;

    private const string FindSql = $"""
        SELECT {Columns}
        FROM exercise_catalog
        WHERE id = @id AND is_published
        """;

    // Only public, reviewed media; newest content version per kind.
    private const string MediaSql = """
        SELECT DISTINCT ON (exercise_id, kind)
               exercise_id AS ExerciseId, id AS Id, kind AS Kind, content_version AS ContentVersion,
               storage_key AS StorageKey, mime_type AS MimeType, sha256 AS Sha256, size_bytes AS SizeBytes,
               duration_ms AS DurationMs, license AS License, attribution AS Attribution
        FROM exercise_media
        WHERE exercise_id = ANY(@ids) AND is_public AND reviewed_at IS NOT NULL
        ORDER BY exercise_id, kind, content_version DESC
        """;

    public async Task<IReadOnlyList<CatalogExercise>> ListAsync(
        ExerciseFilter filter, ExerciseCursor? after, int take, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(filter);
        var parameters = new
        {
            type = filter.Type,
            equipment = filter.Equipment,
            pattern = filter.Query is null ? null : $"%{EscapeLike(filter.Query)}%",
            afterSlug = after?.Slug,
            afterId = after?.Id,
            take,
        };

        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        var rows = (await connection.QueryAsync<ExerciseRow>(
            new CommandDefinition(ListSql, parameters, cancellationToken: cancellationToken)).ConfigureAwait(false)).AsList();
        return await AttachMediaAsync(connection, rows, cancellationToken).ConfigureAwait(false);
    }

    public async Task<CatalogExercise?> FindAsync(Guid id, CancellationToken cancellationToken)
    {
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        var row = await connection.QuerySingleOrDefaultAsync<ExerciseRow>(
            new CommandDefinition(FindSql, new { id }, cancellationToken: cancellationToken)).ConfigureAwait(false);
        if (row is null)
        {
            return null;
        }

        var result = await AttachMediaAsync(connection, [row], cancellationToken).ConfigureAwait(false);
        return result[0];
    }

    private static async Task<IReadOnlyList<CatalogExercise>> AttachMediaAsync(
        NpgsqlConnection connection, List<ExerciseRow> rows, CancellationToken cancellationToken)
    {
        if (rows.Count == 0)
        {
            return [];
        }

        var ids = rows.Select(r => r.Id).ToArray();
        var media = (await connection.QueryAsync<MediaRow>(
                new CommandDefinition(MediaSql, new { ids }, cancellationToken: cancellationToken)).ConfigureAwait(false))
            .ToLookup(m => m.ExerciseId);

        return rows.Select(r => new CatalogExercise(
                r.Id, r.Slug, r.Name, r.Type, r.Discipline,
                ParseStrings(r.FocusTagsJson), ParseStrings(r.EquipmentJson), ParseStrings(r.CuesJson),
                r.CatalogVersion,
                media[r.Id].Select(m => new CatalogMedia(
                    m.Id, m.Kind, m.ContentVersion, m.StorageKey, m.MimeType, m.Sha256.Trim(),
                    m.SizeBytes, m.DurationMs, m.License, m.Attribution)).ToArray()))
            .ToArray();
    }

    private static string[] ParseStrings(string? json) =>
        string.IsNullOrEmpty(json) ? [] : JsonSerializer.Deserialize<string[]>(json) ?? [];

    /// <summary>Escapes LIKE metacharacters so user input is matched literally.</summary>
    internal static string EscapeLike(string value) =>
        value.Replace(@"\", @"\\", StringComparison.Ordinal)
            .Replace("%", @"\%", StringComparison.Ordinal)
            .Replace("_", @"\_", StringComparison.Ordinal);

    private sealed class ExerciseRow
    {
        public Guid Id { get; init; }
        public string Slug { get; init; } = string.Empty;
        public string Name { get; init; } = string.Empty;
        public string Type { get; init; } = string.Empty;
        public string Discipline { get; init; } = string.Empty;
        public string? FocusTagsJson { get; init; }
        public string? EquipmentJson { get; init; }
        public string? CuesJson { get; init; }
        public int CatalogVersion { get; init; }
    }

    private sealed class MediaRow
    {
        public Guid ExerciseId { get; init; }
        public Guid Id { get; init; }
        public string Kind { get; init; } = string.Empty;
        public int ContentVersion { get; init; }
        public string StorageKey { get; init; } = string.Empty;
        public string MimeType { get; init; } = string.Empty;
        public string Sha256 { get; init; } = string.Empty;
        public long? SizeBytes { get; init; }
        public long? DurationMs { get; init; }
        public string License { get; init; } = string.Empty;
        public string? Attribution { get; init; }
    }
}
