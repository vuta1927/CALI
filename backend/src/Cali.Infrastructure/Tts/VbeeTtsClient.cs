using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Cali.Application.VoicePublishing;
using Cali.Infrastructure.Audio;

namespace Cali.Infrastructure.Tts;

/// <summary>
/// vbee.vn credentials and voice (ADR-077). Env <c>Tts__Vbee__AppId</c>, <c>Tts__Vbee__Token</c> (secret),
/// <c>Tts__Vbee__VoiceCode</c>. A class, not a record, so a generated <c>ToString</c> can never print the token.
/// </summary>
public sealed class VbeeOptions
{
    public const string SectionName = "Tts:Vbee";

    public required string AppId { get; init; }

    public required string Token { get; init; }

    /// <summary>vbee voice code; list them with <c>Cali.VoicePack list-voices</c>.</summary>
    public required string VoiceCode { get; init; }

    /// <summary>Hz; supported values depend on the voice (vbee docs). 22050 keeps cues small.</summary>
    public int SampleRate { get; init; } = 22050;

    /// <summary>0.25..1.9, vbee default 1.0.</summary>
    public double Speed { get; init; } = 1.0;

    public Uri TtsEndpoint { get; init; } = new("https://api.vbee.vn/v1/tts");

    /// <summary>
    /// vbee requires a webhook for async requests, but the client polls <c>{TtsEndpoint}/requests/{id}</c> instead, so
    /// the default is an RFC 2606 <c>.invalid</c> host that can never receive anything. Env <c>Tts__Vbee__WebhookUrl</c>.
    /// </summary>
    public Uri WebhookUrl { get; init; } = DefaultWebhookUrl;

    public static readonly Uri DefaultWebhookUrl = new("https://callback.invalid/vbee");

    /// <summary>Wait between status polls; a short cue is usually ready within a few seconds.</summary>
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>Give up on a request still PROCESSING after this many polls.</summary>
    public int MaxPolls { get; init; } = 120;

    public Uri VoicesEndpoint { get; init; } = new("https://vbee.vn/api/public/v1/voices");
}

/// <summary>A vbee refusal: its <c>error.code</c> (e.g. UNAUTHORIZED, BAD_REQUEST) and message, never the request headers.</summary>
public sealed class VbeeException(HttpStatusCode status, string code, string message)
    : Exception($"vbee {(int)status} {code}: {message}")
{
    public HttpStatusCode Status { get; } = status;

    public string Code { get; } = code;
}

public sealed record VbeeVoice(string Code, string Name, string Gender, string LanguageCode);

/// <summary>
/// vbee TTS API in async mode (https://api-docs.vbee.vn/vbee-api/text-to-speech/realtime-api): <c>POST /v1/tts</c> with
/// <c>mode: async</c> returns a request id, <c>GET /v1/tts/requests/{id}</c> is polled until COMPLETED, then the WAV is
/// downloaded from <c>audioLink</c> without our credentials. Sync mode is not used: not every vbee package allows it
/// ("This feature is not supported in user package"). Errors arrive as <c>{"error":{"code","message"}}</c>;
/// TTS_CCR_MAX_LIMIT_REACHED (429) and 5xx are retried a few times with backoff, every other error is final.
/// </summary>
public sealed class VbeeTtsClient(HttpClient http, VbeeOptions options, Func<TimeSpan, CancellationToken, Task>? delay = null)
{
    public const int MaxTextLength = 300;
    private const int MaxAttempts = 4;

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly Func<TimeSpan, CancellationToken, Task> _delay = delay ?? Task.Delay;

    /// <summary>16-bit PCM WAV of <paramref name="text"/> in the configured voice.</summary>
    public async Task<byte[]> SynthesizeWavAsync(string text, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(text);
        if (text.Trim().Length > MaxTextLength)
        {
            throw new ArgumentException($"vbee accepts at most {MaxTextLength} characters.", nameof(text));
        }

        var body = new SynthesizeRequest(text, "async", options.VoiceCode, "wav", options.SampleRate, options.Speed, options.WebhookUrl);
        var submitted = await SendJsonAsync(
            () => new HttpRequestMessage(HttpMethod.Post, options.TtsEndpoint) { Content = JsonContent.Create(body, options: Json) },
            cancellationToken).ConfigureAwait(false);
        var requestId = submitted.RequestId is { Length: > 0 } id && id.All(c => char.IsAsciiLetterOrDigit(c) || c == '-')
            ? id
            : throw new VbeeException(HttpStatusCode.OK, "INVALID_RESPONSE", "no request id");

        var statusUri = new Uri(options.TtsEndpoint.AbsoluteUri.TrimEnd('/') + "/requests/" + requestId);
        var status = submitted;
        for (var poll = 0; IsProcessing(status); poll++)
        {
            if (poll == options.MaxPolls)
            {
                throw new VbeeException(HttpStatusCode.RequestTimeout, "TTS_TIMEOUT", $"request {requestId} still {status.Status} after {poll} polls");
            }

            await _delay(options.PollInterval, cancellationToken).ConfigureAwait(false);
            status = await SendJsonAsync(() => new HttpRequestMessage(HttpMethod.Get, statusUri), cancellationToken).ConfigureAwait(false);
        }

        if (!string.Equals(status.Status, "COMPLETED", StringComparison.OrdinalIgnoreCase)
            || !Uri.TryCreate(status.AudioLink, UriKind.Absolute, out var audioLink) || audioLink.Scheme != Uri.UriSchemeHttps)
        {
            throw new VbeeException(HttpStatusCode.OK, "TTS_FAILED", $"request {requestId} ended {status.Status ?? "without status"}");
        }

        // No Authorization/App-Id: the link is a capability URL and our credentials stay with the API host.
        using var response = await http.GetAsync(audioLink, cancellationToken).ConfigureAwait(false);
        var wav = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode || wav.Length < 12 || !wav.AsSpan(0, 4).SequenceEqual("RIFF"u8))
        {
            throw new VbeeException(response.StatusCode, "INVALID_AUDIO", $"request {requestId} audio is not a WAV file");
        }

        return wav;
    }

    private static bool IsProcessing(RequestStatus status) =>
        status.Status is null
        || string.Equals(status.Status, "PROCESSING", StringComparison.OrdinalIgnoreCase)
        || string.Equals(status.Status, "PENDING", StringComparison.OrdinalIgnoreCase);

    private async Task<RequestStatus> SendJsonAsync(Func<HttpRequestMessage> create, CancellationToken cancellationToken)
    {
        for (var attempt = 1; ; attempt++)
        {
            using var request = create();
            Authorize(request);
            using var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
            var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
            if (response.IsSuccessStatusCode)
            {
                RequestStatus? value;
                try
                {
                    value = JsonSerializer.Deserialize<RequestStatus>(bytes, Json);
                }
                catch (JsonException)
                {
                    throw new VbeeException(response.StatusCode, "INVALID_RESPONSE", "response is not JSON");
                }

                if (value is { Error: null })
                {
                    return value;
                }
            }

            var error = ParseError(response.StatusCode, bytes);
            var retryable = response.StatusCode == HttpStatusCode.TooManyRequests || (int)response.StatusCode >= 500;
            if (!retryable || attempt == MaxAttempts)
            {
                throw error;
            }

            await _delay(TimeSpan.FromSeconds(Math.Pow(2, attempt - 1)), cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>Voices for <paramref name="languageCode"/> (all of them; only some work with the Realtime API).</summary>
    public async Task<IReadOnlyList<VbeeVoice>> ListVoicesAsync(string languageCode, CancellationToken cancellationToken)
    {
        var voices = new List<VbeeVoice>();
        string? cursor = null;
        do
        {
            var url = string.Create(CultureInfo.InvariantCulture,
                $"{options.VoicesEndpoint}?language_code={Uri.EscapeDataString(languageCode)}&limit=100{(cursor is null ? "" : "&cursor=" + Uri.EscapeDataString(cursor))}");
            using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(url));
            Authorize(request);
            using var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
            var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw ParseError(response.StatusCode, bytes);
            }

            var page = JsonSerializer.Deserialize<VoicesResponse>(bytes, Json)?.Result
                ?? throw new VbeeException(response.StatusCode, "INVALID_RESPONSE", "voices response has no result");
            voices.AddRange(page.Voices.Select(v => new VbeeVoice(v.Code, v.Name, v.Gender, v.LanguageCode)));
            cursor = page.Pagination is { HasNextPage: true, NextCursor: { Length: > 0 } next } ? next : null;
        }
        while (cursor is not null);

        return voices;
    }

    private void Authorize(HttpRequestMessage request)
    {
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", options.Token);
        request.Headers.Add("App-Id", options.AppId);
    }

    private static VbeeException ParseError(HttpStatusCode status, byte[] body)
    {
        try
        {
            var error = JsonSerializer.Deserialize<ErrorResponse>(body, Json)?.Error;
            if (error is { Code: { Length: > 0 } code })
            {
                return new VbeeException(status, code, error.Message ?? string.Empty);
            }
        }
        catch (JsonException)
        {
            // Not the documented error shape; fall through.
        }

        return new VbeeException(status, "UNEXPECTED_RESPONSE", status == HttpStatusCode.OK ? "error-shaped body" : "no error body");
    }

    private sealed record SynthesizeRequest(string Text, string Mode, string VoiceCode, string OutputFormat, int SampleRate, double Speed, Uri WebhookUrl);

    private sealed record RequestStatus(string? RequestId, string? Status, string? AudioLink, ErrorBody? Error);

    private sealed record ErrorResponse(ErrorBody? Error);

    private sealed record ErrorBody(string? Code, string? Message);

    private sealed record VoicesResponse(VoicesResult? Result);

    private sealed record VoicesResult(Pagination? Pagination, IReadOnlyList<VoiceRow> Voices);

    private sealed record Pagination(
        [property: JsonPropertyName("has_next_page")] bool HasNextPage,
        [property: JsonPropertyName("next_cursor")] string? NextCursor);

    private sealed record VoiceRow(
        string Code, string Name, string Gender, [property: JsonPropertyName("language_code")] string LanguageCode);
}

/// <summary><see cref="ICueRenderer"/> on vbee: WAV from the Realtime API, converted to CAF IMA4 mono.</summary>
public sealed class VbeeCueRenderer(VbeeTtsClient client, VbeeOptions options) : ICueRenderer
{
    public string VoiceLabel => $"vbee {options.VoiceCode}";

    public async Task<RenderedCue> RenderAsync(string text, CancellationToken cancellationToken)
    {
        var wav = await client.SynthesizeWavAsync(text, cancellationToken).ConfigureAwait(false);
        var pcm = WavReader.Read(wav);
        return new RenderedCue(CafWriter.WriteIma4(pcm), pcm.DurationMs);
    }
}
