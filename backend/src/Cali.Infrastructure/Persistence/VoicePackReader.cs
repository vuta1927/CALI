using Cali.Application.Catalog;
using Cali.Domain.Catalog;
using Dapper;
using Npgsql;

namespace Cali.Infrastructure.Persistence;

/// <summary>Reads <c>voice_pack_versions</c> and <c>voice_cues</c> (db/011, CON-010).</summary>
public sealed class VoicePackReader(NpgsqlDataSource dataSource) : IVoicePackReader
{
    // One statement, so the version row and its cues come from the same snapshot. A published pack is immutable,
    // but the latest version may be published between two separate reads.
    private const string Sql = """
        WITH pack AS (
            SELECT locale, version, published_at, voice
            FROM voice_pack_versions
            WHERE locale = @locale AND (CAST(@version AS integer) IS NULL OR version = @version)
            ORDER BY version DESC
            LIMIT 1
        )
        SELECT p.locale AS Locale, p.version AS Version, p.published_at AS PublishedAt, p.voice AS Voice,
               c.cue_key AS CueKey, c.text AS Text, c.storage_key AS StorageKey, c.format AS Format,
               c.sha256 AS Sha256, c.byte_size AS ByteSize, c.duration_ms AS DurationMs
        FROM pack p
        LEFT JOIN voice_cues c ON c.locale = p.locale AND c.version = p.version
        ORDER BY c.cue_key
        """;

    public async Task<VoicePack?> FindAsync(string locale, int? version, CancellationToken cancellationToken)
    {
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        var rows = (await connection.QueryAsync<Row>(
            new CommandDefinition(Sql, new { locale, version }, cancellationToken: cancellationToken)).ConfigureAwait(false)).AsList();
        if (rows.Count == 0)
        {
            return null;
        }

        var first = rows[0];
        var cues = rows.Where(r => r.CueKey is not null)
            .Select(r => new VoiceCue(r.CueKey!, r.Text!, r.StorageKey!, r.Format!, r.Sha256!, r.ByteSize!.Value, r.DurationMs!.Value))
            .ToArray();
        return new VoicePack(first.Locale, first.Version, new DateTimeOffset(DateTime.SpecifyKind(first.PublishedAt, DateTimeKind.Utc)), first.Voice, cues);
    }

    private sealed class Row
    {
        public string Locale { get; init; } = string.Empty;
        public int Version { get; init; }
        public DateTime PublishedAt { get; init; }
        public string Voice { get; init; } = string.Empty;
        public string? CueKey { get; init; }
        public string? Text { get; init; }
        public string? StorageKey { get; init; }
        public string? Format { get; init; }
        public string? Sha256 { get; init; }
        public int? ByteSize { get; init; }
        public int? DurationMs { get; init; }
    }
}
