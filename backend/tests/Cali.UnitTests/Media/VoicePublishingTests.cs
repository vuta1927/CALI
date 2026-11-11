using System.Net;
using System.Text;
using System.Text.Json;
using Cali.Application.Catalog;
using Cali.Application.VoicePublishing;
using Cali.Domain.Catalog;
using Cali.Infrastructure.Tts;
using Cali.Tests.Shared;
using Microsoft.Extensions.Time.Testing;

namespace Cali.UnitTests.Media;

/// <summary>BE-007 (CON-010, ADR-077): vbee client, cue script and publisher.</summary>
public sealed class VoicePublishingTests
{
    private const string Token = "secret-vbee-token-value";

    private static VbeeOptions Options => new() { AppId = "app-1", Token = Token, VoiceCode = "sg_female_tuongvy_test" };

    private static byte[] SpeechWav(double seconds = 1.2) =>
        VoiceAudioTests.Wav(22050, Enumerable.Range(0, (int)(22050 * seconds)).Select(i => (short)(8000 * Math.Sin(i / 7.0))).ToArray());

    // ---- vbee client ----

    [Fact]
    public async Task Synthesize_sends_the_documented_realtime_request_and_returns_the_audio()
    {
        var handler = new StubHandler(_ => Audio(SpeechWav()));
        var client = new VbeeTtsClient(new HttpClient(handler), Options);

        var wav = await client.SynthesizeWavAsync("Hết giờ nghỉ.", CancellationToken.None);

        wav.ShouldBe(SpeechWav());
        var request = handler.Requests.Single();
        request.Method.ShouldBe(HttpMethod.Post);
        request.Uri.ShouldBe(new Uri("https://api.vbee.vn/v1/tts"));
        request.Authorization.ShouldBe($"Bearer {Token}");
        request.AppId.ShouldBe("app-1");
        using var body = JsonDocument.Parse(request.Body!);
        var root = body.RootElement;
        root.GetProperty("text").GetString().ShouldBe("Hết giờ nghỉ.");
        root.GetProperty("mode").GetString().ShouldBe("sync");
        root.GetProperty("voiceCode").GetString().ShouldBe("sg_female_tuongvy_test");
        root.GetProperty("outputFormat").GetString().ShouldBe("wav");
        root.GetProperty("sampleRate").GetInt32().ShouldBe(22050);
    }

    [Fact]
    public async Task Concurrency_limit_and_server_errors_are_retried_with_backoff()
    {
        var responses = new Queue<HttpResponseMessage>([Error(HttpStatusCode.TooManyRequests, "TTS_CCR_MAX_LIMIT_REACHED"), Error(HttpStatusCode.InternalServerError, "INTERNAL_SERVER_ERROR"), Audio(SpeechWav())]);
        var waits = new List<TimeSpan>();
        var client = new VbeeTtsClient(new HttpClient(new StubHandler(_ => responses.Dequeue())), Options, (d, _) => { waits.Add(d); return Task.CompletedTask; });

        (await client.SynthesizeWavAsync("Câu.", CancellationToken.None)).ShouldNotBeEmpty();

        waits.ShouldBe([TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2)]);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized, "UNAUTHORIZED")]
    [InlineData(HttpStatusCode.BadRequest, "BAD_REQUEST")]
    public async Task Client_errors_fail_at_once_without_leaking_the_token(HttpStatusCode status, string code)
    {
        var handler = new StubHandler(_ => Error(status, code));
        var client = new VbeeTtsClient(new HttpClient(handler), Options, (_, _) => throw new InvalidOperationException("must not retry"));

        var error = await Should.ThrowAsync<VbeeException>(() => client.SynthesizeWavAsync("Câu.", CancellationToken.None));

        error.Code.ShouldBe(code);
        error.Status.ShouldBe(status);
        error.ToString().ShouldNotContain(Token);
        handler.Requests.Count.ShouldBe(1);
    }

    [Fact]
    public async Task A_json_body_with_status_200_is_an_error_not_audio()
    {
        var client = new VbeeTtsClient(new HttpClient(new StubHandler(_ => Error(HttpStatusCode.OK, "BAD_REQUEST"))), Options);

        (await Should.ThrowAsync<VbeeException>(() => client.SynthesizeWavAsync("Câu.", CancellationToken.None))).Code.ShouldBe("BAD_REQUEST");
    }

    [Fact]
    public async Task Text_over_the_vbee_limit_is_refused_before_any_call()
    {
        var handler = new StubHandler(_ => Audio(SpeechWav()));

        await Should.ThrowAsync<ArgumentException>(() =>
            new VbeeTtsClient(new HttpClient(handler), Options).SynthesizeWavAsync(new string('a', 301), CancellationToken.None));
        handler.Requests.ShouldBeEmpty();
    }

    [Fact]
    public async Task List_voices_follows_the_cursor()
    {
        var pages = new Queue<string>([
            """{"result":{"pagination":{"has_next_page":true,"next_cursor":"c2"},"voices":[{"code":"a","name":"HN - Ngọc Huyền","gender":"female","language_code":"vi-VN"}]},"status":1}""",
            """{"result":{"pagination":{"has_next_page":false,"next_cursor":null},"voices":[{"code":"b","name":"SG - Tường Vy","gender":"female","language_code":"vi-VN"}]},"status":1}""",
        ]);
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(pages.Dequeue(), Encoding.UTF8, "application/json") });

        var voices = await new VbeeTtsClient(new HttpClient(handler), Options).ListVoicesAsync("vi-VN", CancellationToken.None);

        voices.Select(v => v.Name).ShouldBe(["HN - Ngọc Huyền", "SG - Tường Vy"]);
        handler.Requests[0].Uri.Query.ShouldBe("?language_code=vi-VN&limit=100");
        handler.Requests[1].Uri.Query.ShouldBe("?language_code=vi-VN&limit=100&cursor=c2");
        handler.Requests.ShouldAllBe(r => r.AppId == "app-1");
    }

    [Fact]
    public async Task Renderer_turns_vbee_wav_into_caf_with_its_duration()
    {
        var renderer = new VbeeCueRenderer(new VbeeTtsClient(new HttpClient(new StubHandler(_ => Audio(SpeechWav(1.5)))), Options), Options);

        var cue = await renderer.RenderAsync("Câu.", CancellationToken.None);

        cue.DurationMs.ShouldBe(1500);
        Encoding.ASCII.GetString(cue.Caf, 0, 4).ShouldBe("caff");
        renderer.VoiceLabel.ShouldBe("vbee sg_female_tuongvy_test");
    }

    // ---- script ----

    [Fact]
    public void The_committed_vi_VN_script_parses()
    {
        var script = VoiceCueScript.Parse(File.ReadAllText(Path.Combine(RepoPaths.RepoRoot, "fixtures", "voice_cues.vi-VN.json")));

        script.Locale.ShouldBe("vi-VN");
        script.Cues.Count.ShouldBe(8);
        script.Cues.ShouldContain(c => c.Key == "rest.done" && c.Text == "Hết giờ nghỉ. Vào set tiếp theo.");
    }

    [Theory]
    [InlineData("""{"locale":"vi","cues":[{"key":"rest.done","text":"A."}]}""")]
    [InlineData("""{"locale":"vi-VN","cues":[]}""")]
    [InlineData("""{"locale":"vi-VN","cues":[{"key":"Rest","text":"A."}]}""")]
    [InlineData("""{"locale":"vi-VN","cues":[{"key":"rest.done","text":" A."}]}""")]
    [InlineData("""{"locale":"vi-VN","cues":[{"key":"rest.done","text":"A."},{"key":"rest.done","text":"B."}]}""")]
    public void Invalid_scripts_are_refused(string json) =>
        Should.Throw<FormatException>(() => VoiceCueScript.Parse(json));

    // ---- publisher ----

    private static readonly VoiceCueScript Script = new("vi-VN", [new("rest.done", "Hết giờ nghỉ."), new("hold.done", "Đủ thời gian.")]);

    [Fact]
    public async Task Publishes_the_next_version_with_uploaded_files_and_their_hashes()
    {
        var reader = new FakeReader(new VoicePack("vi-VN", 4, DateTimeOffset.UnixEpoch, "vbee old", []));
        var uploader = new FakeUploader();
        var writer = new FakeWriter();
        var time = new FakeTimeProvider(new DateTimeOffset(2026, 11, 11, 3, 0, 0, TimeSpan.Zero));

        var result = await new VoicePackPublisher(new FakeRenderer(), uploader, reader, writer, time)
            .PublishAsync(Script, force: false, progress: null, CancellationToken.None);

        var pack = result.ShouldBeOfType<PublishResult.Published>().Pack;
        pack.Version.ShouldBe(5);
        pack.PublishedAt.ShouldBe(time.GetUtcNow());
        pack.Voice.ShouldBe("vbee test");
        uploader.Puts.Select(p => p.Key).ShouldBe(["voice/vi-VN/v5/rest.done.caf", "voice/vi-VN/v5/hold.done.caf"]);
        uploader.Puts.ShouldAllBe(p => p.ContentType == "audio/x-caf");
        var cue = pack.Cues[0];
        cue.Sha256.ShouldBe(Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(uploader.Puts[0].Content)));
        cue.ByteSize.ShouldBe(uploader.Puts[0].Content.Length);
        cue.Format.ShouldBe("caf_ima4");
        writer.Published.ShouldBe([pack]);
    }

    [Fact]
    public async Task Same_voice_and_sentences_publish_nothing_unless_forced()
    {
        var latest = new VoicePack("vi-VN", 2, DateTimeOffset.UnixEpoch, "vbee test",
            Script.Cues.Select(c => new VoiceCue(c.Key, c.Text, "k", "caf_ima4", new string('a', 64), 10, 10)).ToArray());
        var renderer = new FakeRenderer();
        var writer = new FakeWriter();
        var publisher = new VoicePackPublisher(renderer, new FakeUploader(), new FakeReader(latest), writer, TimeProvider.System);

        (await publisher.PublishAsync(Script, force: false, null, CancellationToken.None)).ShouldBe(new PublishResult.Unchanged(2));
        renderer.Calls.ShouldBe(0);

        (await publisher.PublishAsync(Script, force: true, null, CancellationToken.None)).ShouldBeOfType<PublishResult.Published>().Pack.Version.ShouldBe(3);
    }

    [Fact]
    public async Task First_pack_is_version_1_and_a_too_long_cue_stops_before_publishing()
    {
        var writer = new FakeWriter();
        var ok = await new VoicePackPublisher(new FakeRenderer(), new FakeUploader(), new FakeReader(null), writer, TimeProvider.System)
            .PublishAsync(Script, false, null, CancellationToken.None);
        ok.ShouldBeOfType<PublishResult.Published>().Pack.Version.ShouldBe(1);

        var tooLong = new VoicePackPublisher(new FakeRenderer(durationMs: 30_001), new FakeUploader(), new FakeReader(null), new FakeWriter(), TimeProvider.System);
        await Should.ThrowAsync<InvalidOperationException>(() => tooLong.PublishAsync(Script, false, null, CancellationToken.None));
    }

    // ---- fakes ----

    private static HttpResponseMessage Audio(byte[] wav) =>
        new(HttpStatusCode.OK) { Content = new ByteArrayContent(wav) { Headers = { ContentType = new("audio/wav") } } };

    private static HttpResponseMessage Error(HttpStatusCode status, string code) =>
        new(status) { Content = new StringContent($$$"""{"error":{"code":"{{{code}}}","message":"m"}}""", Encoding.UTF8, "application/json") };

    private sealed record SeenRequest(HttpMethod Method, Uri Uri, string? Authorization, string? AppId, string? Body);

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public List<SeenRequest> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(new SeenRequest(request.Method, request.RequestUri!, request.Headers.Authorization?.ToString(),
                request.Headers.TryGetValues("App-Id", out var ids) ? ids.Single() : null,
                request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken)));
            return respond(request);
        }
    }

    private sealed class FakeRenderer(int durationMs = 1500) : ICueRenderer
    {
        public int Calls { get; private set; }

        public string VoiceLabel => "vbee test";

        public Task<RenderedCue> RenderAsync(string text, CancellationToken cancellationToken)
        {
            Calls++;
            return Task.FromResult(new RenderedCue(Encoding.UTF8.GetBytes("caff" + text), durationMs));
        }
    }

    private sealed class FakeUploader : IObjectUploader
    {
        public List<(string Key, byte[] Content, string ContentType)> Puts { get; } = [];

        public Task PutAsync(string storageKey, byte[] content, string contentType, CancellationToken cancellationToken)
        {
            Puts.Add((storageKey, content, contentType));
            return Task.CompletedTask;
        }
    }

    private sealed class FakeReader(VoicePack? latest) : IVoicePackReader
    {
        public Task<VoicePack?> FindAsync(string locale, int? version, CancellationToken cancellationToken) => Task.FromResult(latest);
    }

    private sealed class FakeWriter : IVoicePackWriter
    {
        public List<VoicePack> Published { get; } = [];

        public Task PublishAsync(VoicePack pack, CancellationToken cancellationToken)
        {
            Published.Add(pack);
            return Task.CompletedTask;
        }
    }
}
