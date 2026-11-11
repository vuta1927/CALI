using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using Cali.Application.Catalog;
using Cali.Domain.Catalog;

namespace Cali.Application.VoicePublishing;

/// <summary>Turns one sentence into a playable cue file (TTS + conversion to CAF IMA4).</summary>
public interface ICueRenderer
{
    /// <summary>Display label of the voice, stored as <c>voice_pack_versions.voice</c>; never a credential.</summary>
    string VoiceLabel { get; }

    Task<RenderedCue> RenderAsync(string text, CancellationToken cancellationToken);
}

public sealed record RenderedCue(byte[] Caf, int DurationMs);

public interface IObjectUploader
{
    Task PutAsync(string storageKey, byte[] content, string contentType, CancellationToken cancellationToken);
}

public interface IVoicePackWriter
{
    /// <summary>Inserts the version row and all cues in one transaction (db/011). Throws <see cref="VoicePackConflictException"/> if the version exists.</summary>
    Task PublishAsync(VoicePack pack, CancellationToken cancellationToken);
}

public sealed class VoicePackConflictException(string locale, int version)
    : Exception($"Voice pack {locale}.v{version} was published by someone else; run the publisher again.");

/// <summary>The sentence script (fixtures/voice_cues.{locale}.json), input of the publisher.</summary>
public sealed partial record VoiceCueScript(string Locale, IReadOnlyList<VoiceCueLine> Cues)
{
    public const int MaxTextLength = 80;
    public const int MaxCues = 64;

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public static VoiceCueScript Parse(string json)
    {
        var script = JsonSerializer.Deserialize<VoiceCueScript>(json, Json)
            ?? throw new FormatException("The voice cue script is empty.");
        script.Validate();
        return script;
    }

    private void Validate()
    {
        if (Locale is null || !GetVoicePack.IsLocale(Locale))
        {
            throw new FormatException("The script locale must be a language-region tag such as vi-VN.");
        }

        if (Cues is not { Count: > 0 and <= MaxCues })
        {
            throw new FormatException($"The script must have 1..{MaxCues} cues.");
        }

        var duplicate = Cues.GroupBy(c => c.Key, StringComparer.Ordinal).FirstOrDefault(g => g.Count() > 1);
        if (duplicate is not null)
        {
            throw new FormatException($"Cue key '{duplicate.Key}' appears more than once.");
        }

        foreach (var cue in Cues)
        {
            if (cue.Key is null || !KeyPattern().IsMatch(cue.Key))
            {
                throw new FormatException($"Cue key '{cue.Key}' does not match VoiceCueKey.");
            }

            if (string.IsNullOrWhiteSpace(cue.Text) || cue.Text.Length > MaxTextLength || cue.Text != cue.Text.Trim())
            {
                throw new FormatException($"Cue '{cue.Key}' text must be 1..{MaxTextLength} characters without surrounding spaces.");
            }
        }
    }

    // OpenAPI VoiceCueKey / db/011 ck_voice_cues_key.
    [GeneratedRegex(@"^[a-z][a-z0-9_]{0,31}(\.[a-z0-9_]{1,32}){1,3}$", RegexOptions.CultureInvariant)]
    private static partial Regex KeyPattern();
}

public sealed record VoiceCueLine(string Key, string Text);

public abstract record PublishResult
{
    public sealed record Unchanged(int Version) : PublishResult;

    public sealed record Published(VoicePack Pack) : PublishResult;
}

/// <summary>
/// BE-007 (CON-010, ADR-077): renders every sentence of the script, uploads the files under keys that name the new
/// version, then publishes the version in one transaction. Files are uploaded before the rows exist, so a failure
/// leaves at most unreferenced objects, never a pack pointing at missing audio. Nothing is rendered (and no TTS credit
/// spent) when the latest pack already has the same voice and sentences, unless <c>force</c> is set.
/// </summary>
public sealed class VoicePackPublisher(ICueRenderer renderer, IObjectUploader uploader, IVoicePackReader reader, IVoicePackWriter writer, TimeProvider time)
{
    public const string ContentType = "audio/x-caf";
    public const int MaxBytes = 1_048_576;
    public const int MaxDurationMs = 30_000;

    public async Task<PublishResult> PublishAsync(VoiceCueScript script, bool force, IProgress<string>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(script);
        var latest = await reader.FindAsync(script.Locale, null, cancellationToken).ConfigureAwait(false);
        if (!force && latest is not null && SameContent(latest, script, renderer.VoiceLabel))
        {
            return new PublishResult.Unchanged(latest.Version);
        }

        var version = (latest?.Version ?? 0) + 1;
        var cues = new List<VoiceCue>(script.Cues.Count);
        foreach (var line in script.Cues)
        {
            var rendered = await renderer.RenderAsync(line.Text, cancellationToken).ConfigureAwait(false);
            Check(line.Key, rendered);
            var key = StorageKey(script.Locale, version, line.Key);
            await uploader.PutAsync(key, rendered.Caf, ContentType, cancellationToken).ConfigureAwait(false);
            cues.Add(new VoiceCue(line.Key, line.Text, key, "caf_ima4", Convert.ToHexStringLower(SHA256.HashData(rendered.Caf)),
                rendered.Caf.Length, rendered.DurationMs));
            progress?.Report(string.Create(CultureInfo.InvariantCulture, $"{line.Key}: {rendered.DurationMs} ms, {rendered.Caf.Length} bytes"));
        }

        var pack = new VoicePack(script.Locale, version, time.GetUtcNow(), renderer.VoiceLabel, cues);
        await writer.PublishAsync(pack, cancellationToken).ConfigureAwait(false);
        return new PublishResult.Published(pack);
    }

    /// <summary>Opaque per version and immutable (ADR-072): a new version never overwrites a file clients cached.</summary>
    public static string StorageKey(string locale, int version, string cueKey) =>
        string.Create(CultureInfo.InvariantCulture, $"voice/{locale}/v{version}/{cueKey}.caf");

    internal static void Check(string key, RenderedCue rendered)
    {
        if (rendered.Caf.Length is 0 or > MaxBytes)
        {
            throw new InvalidOperationException($"Cue '{key}' audio is {rendered.Caf.Length} bytes; allowed 1..{MaxBytes}.");
        }

        if (rendered.DurationMs is < 1 or > MaxDurationMs)
        {
            throw new InvalidOperationException($"Cue '{key}' lasts {rendered.DurationMs} ms; iOS notification sounds allow at most {MaxDurationMs} ms.");
        }
    }

    private static bool SameContent(VoicePack latest, VoiceCueScript script, string voice) =>
        latest.Voice == voice
        && latest.Cues.Count == script.Cues.Count
        && script.Cues.All(line => latest.Cues.Any(c => c.Key == line.Key && c.Text == line.Text));
}
