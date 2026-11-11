using System.Globalization;
using System.Text.RegularExpressions;
using Cali.Domain.Catalog;

namespace Cali.Application.Catalog;

public interface IVoicePackReader
{
    /// <summary>The published pack <paramref name="version"/> for <paramref name="locale"/>, or the latest when null; null when none.</summary>
    Task<VoicePack?> FindAsync(string locale, int? version, CancellationToken cancellationToken);
}

/// <summary>Use case behind <c>GET /v1/voice-pack</c> (CON-010, ADR-077).</summary>
public sealed partial class GetVoicePack(IVoicePackReader reader)
{
    /// <summary>OpenAPI <c>VoiceLocale</c>; db/011 <c>ck_voice_pack_versions_locale</c>.</summary>
    public static bool IsLocale(string value) => LocalePattern().IsMatch(value);

    /// <summary><c>"{locale}.v{version}"</c>, quoted as an HTTP entity tag. A published pack never changes (db/011).</summary>
    public static string ETag(VoicePack pack) => string.Create(CultureInfo.InvariantCulture, $"\"{pack.Locale}.v{pack.Version}\"");

    public Task<VoicePack?> ExecuteAsync(string locale, int? version, CancellationToken cancellationToken) =>
        reader.FindAsync(locale, version, cancellationToken);

    [GeneratedRegex("^[a-z]{2,3}-[A-Z]{2}$", RegexOptions.CultureInvariant)]
    private static partial Regex LocalePattern();
}
