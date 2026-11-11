using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using Cali.Application.VoicePublishing;
using Cali.Domain.Catalog;
using Cali.Infrastructure.Audio;
using Cali.Infrastructure.Media;
using Cali.Infrastructure.Persistence;
using Cali.IntegrationTests.Infrastructure;
using DotNet.Testcontainers.Builders;
using Npgsql;

namespace Cali.IntegrationTests;

/// <summary>
/// BE-007 (CON-010, ADR-077): the publisher uploads to a real S3-compatible server and publishes into PostgreSQL, and
/// the API then serves URLs that download exactly the published bytes. Only the TTS call is faked (it costs credit).
/// </summary>
[Collection(PostgresCollection.Name)]
public sealed class VoicePackPublishingTests(PostgresFixture postgres)
{
    // Same pinned image as S3CompatibleStoreTests.
    private const string StoreImage = "zenko/cloudserver@sha256:b53e57829cf7df357323e60a19c9f98d2218f1b7ccb1d7cea5761a5a227a9ee3";
    private const string AccessKeyId = "cali-test-key";
    private const string Secret = "cali-test-secret-value";
    private const string Region = "us-east-1";
    private const string Bucket = "cali-media";

    private static readonly HttpClient Http = new();

    private static readonly VoiceCueScript Script = new("vi-VN", [new("rest.done", "Hết giờ nghỉ. Vào set tiếp theo."), new("hold.done", "Đủ thời gian. Có thể thả.")]);

    [Fact]
    public async Task Published_pack_is_served_with_urls_that_download_the_published_audio()
    {
        await using var container = new ContainerBuilder(StoreImage)
            .WithPortBinding(8000, assignRandomHostPort: true)
            .WithEnvironment("S3BACKEND", "mem")
            .WithEnvironment("SCALITY_ACCESS_KEY_ID", AccessKeyId)
            .WithEnvironment("SCALITY_SECRET_ACCESS_KEY", Secret)
            .WithEnvironment("REMOTE_MANAGEMENT_DISABLE", "1")
            .WithWaitStrategy(Wait.ForUnixContainer().UntilMessageIsLogged("server started"))
            .Build();
        await container.StartAsync();
        var origin = new Uri($"http://{container.Hostname}:{container.GetMappedPublicPort(8000)}");
        await CreateBucketAsync(origin);

        var cs = await postgres.CreateMigratedDatabaseAsync("voice_publish_e2e");
        await using var dataSource = NpgsqlDataSource.Create(cs);
        var storage = new S3StorageOptions
        {
            Endpoint = origin, Bucket = Bucket, Region = Region, AccessKeyId = AccessKeyId, SecretAccessKey = Secret, Lifetime = TimeSpan.FromMinutes(5),
        };
        var publisher = new VoicePackPublisher(new ToneRenderer(), new S3ObjectUploader(Http, storage, TimeProvider.System),
            new VoicePackReader(dataSource), new VoicePackWriter(dataSource), TimeProvider.System);

        var first = await publisher.PublishAsync(Script, force: false, progress: null, CancellationToken.None);
        first.ShouldBeOfType<PublishResult.Published>().Pack.Version.ShouldBe(1);
        // Re-running with the same script spends nothing and publishes nothing.
        (await publisher.PublishAsync(Script, force: false, progress: null, CancellationToken.None)).ShouldBe(new PublishResult.Unchanged(1));

        await using var factory = new CaliApiFactory("Development", new Dictionary<string, string?>
        {
            ["ConnectionStrings:Cali"] = cs,
            ["Media:Storage:Endpoint"] = origin.GetLeftPart(UriPartial.Authority),
            ["Media:Storage:Bucket"] = Bucket,
            ["Media:Storage:Region"] = Region,
            ["Media:Storage:AccessKeyId"] = AccessKeyId,
            ["Media:Storage:SecretAccessKey"] = Secret,
        });
        using var api = factory.CreateClient();
        using var document = JsonDocument.Parse(await api.GetStringAsync(new Uri("/v1/voice-pack?locale=vi-VN", UriKind.Relative)));
        var root = document.RootElement;
        root.GetProperty("version").GetInt32().ShouldBe(1);
        root.GetProperty("voice").GetString().ShouldBe("test tone");
        foreach (var cue in root.GetProperty("cues").EnumerateArray())
        {
            var audio = cue.GetProperty("audio");
            using var download = await Http.GetAsync(new Uri(audio.GetProperty("url").GetString()!));
            download.StatusCode.ShouldBe(HttpStatusCode.OK);
            var bytes = await download.Content.ReadAsByteArrayAsync();
            Convert.ToHexStringLower(SHA256.HashData(bytes)).ShouldBe(audio.GetProperty("sha256").GetString());
            bytes.Length.ShouldBe(audio.GetProperty("byteSize").GetInt32());
            System.Text.Encoding.ASCII.GetString(bytes, 0, 4).ShouldBe("caff");
        }
    }

    [Fact]
    public async Task Publishing_an_existing_version_is_a_conflict_and_leaves_the_pack_untouched()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("voice_writer_conflict");
        await using var dataSource = NpgsqlDataSource.Create(cs);
        var writer = new VoicePackWriter(dataSource);
        VoicePack Pack(string text) => new("vi-VN", 1, DateTimeOffset.UtcNow, "v",
            [new VoiceCue("rest.done", text, "voice/vi-VN/v1/rest.done.caf", "caf_ima4", new string('a', 64), 100, 1000)]);

        await writer.PublishAsync(Pack("Một."), CancellationToken.None);
        await Should.ThrowAsync<VoicePackConflictException>(() => writer.PublishAsync(Pack("Hai."), CancellationToken.None));

        var stored = await new VoicePackReader(dataSource).FindAsync("vi-VN", null, CancellationToken.None);
        stored!.Cues.Single().Text.ShouldBe("Một.");
    }

    private static async Task CreateBucketAsync(Uri origin)
    {
        // The first requests can race the server's startup: retry until it answers at all.
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                var url = S3PresignedUrlSigner.Presign("PUT", origin, $"/{Bucket}", Region, AccessKeyId, Secret, DateTimeOffset.UtcNow, 300);
                using var response = await Http.PutAsync(url, new ByteArrayContent([]));
                response.StatusCode.ShouldBe(HttpStatusCode.OK);
                return;
            }
            catch (HttpRequestException) when (attempt < 30)
            {
                await Task.Delay(500);
            }
        }
    }

    /// <summary>Real CAF IMA4 of a short tone per sentence, so sizes and hashes are those of genuine files.</summary>
    private sealed class ToneRenderer : ICueRenderer
    {
        public string VoiceLabel => "test tone";

        public Task<RenderedCue> RenderAsync(string text, CancellationToken cancellationToken)
        {
            var samples = Enumerable.Range(0, 22050 * text.Length / 20)
                .Select(i => (short)(8000 * Math.Sin(2 * Math.PI * 440 * i / 22050))).ToArray();
            var pcm = new PcmAudio(22050, samples);
            return Task.FromResult(new RenderedCue(CafWriter.WriteIma4(pcm), pcm.DurationMs));
        }
    }
}
