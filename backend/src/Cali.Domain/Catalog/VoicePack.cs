namespace Cali.Domain.Catalog;

/// <summary>A published, immutable voice pack (<c>voice_pack_versions</c> + <c>voice_cues</c>, CON-010, ADR-077).</summary>
public sealed record VoicePack(string Locale, int Version, DateTimeOffset PublishedAt, string Voice, IReadOnlyList<VoiceCue> Cues);

/// <summary>
/// One pre-rendered sentence. <see cref="StorageKey"/> is server-internal (ADR-072): only a signed URL leaves the server.
/// </summary>
public sealed record VoiceCue(string Key, string Text, string StorageKey, string Format, string Sha256, int ByteSize, int DurationMs);
