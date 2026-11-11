using System.Net;
using System.Text.Json;
using Cali.IntegrationTests.Infrastructure;
using static Cali.IntegrationTests.CatalogEndpointTests;

namespace Cali.IntegrationTests;

/// <summary>BE-007 (CON-010, ADR-077): GET /v1/voice-pack.</summary>
[Collection(PostgresCollection.Name)]
public sealed class VoicePackEndpointTests(PostgresFixture postgres)
{
    private static readonly string ShaA = new('a', 64);

    private static CaliApiFactory Factory(string cs, bool withStorage = false)
    {
        var settings = new Dictionary<string, string?> { ["ConnectionStrings:Cali"] = cs };
        if (withStorage)
        {
            settings["Media:Storage:Endpoint"] = "https://store.example.com";
            settings["Media:Storage:Bucket"] = "cali-media";
            settings["Media:Storage:AccessKeyId"] = "AKIAINTEGRATION";
            settings["Media:Storage:SecretAccessKey"] = "integration-test-secret-value-123";
        }

        return new CaliApiFactory("Development", settings);
    }

    // One command = one implicit transaction, as the db/011 insert guard requires.
    private static Task PublishAsync(string cs, string locale, int version, params string[] keys) =>
        ExecuteAsync(cs, $"""
            INSERT INTO voice_pack_versions (locale, version, published_at, voice)
            VALUES ('{locale}', {version}, '2026-11-11T00:00:00Z', 'Giọng thử');
            {string.Concat(keys.Select(k => $"""
                INSERT INTO voice_cues (locale, version, cue_key, text, storage_key, sha256, byte_size, duration_ms)
                VALUES ('{locale}', {version}, '{k}', 'Câu {k}.', 'voice/{locale}/v{version}/{k}.caf', '{ShaA}', 12000, 1800);
                """))}
            """);

    private static async Task<(HttpResponseMessage Response, JsonElement Root)> GetAsync(HttpClient client, string url, string? ifNoneMatch = null)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(url, UriKind.Relative));
        if (ifNoneMatch is not null)
        {
            request.Headers.TryAddWithoutValidation("If-None-Match", ifNoneMatch).ShouldBeTrue();
        }

        var response = await client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();
        if (response.StatusCode != HttpStatusCode.OK)
        {
            return (response, default);
        }

        using var document = JsonDocument.Parse(body);
        return (response, document.RootElement.Clone());
    }

    [Fact]
    public async Task Returns_the_latest_pack_with_signed_urls_and_no_storage_key()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("voice_ok");
        await PublishAsync(cs, "vi-VN", 1, "rest.done");
        await PublishAsync(cs, "vi-VN", 2, "rest.done", "hold.done");
        await using var factory = Factory(cs, withStorage: true);
        using var client = factory.CreateClient();
        var before = DateTimeOffset.UtcNow;

        var (response, root) = await GetAsync(client, "/v1/voice-pack?locale=vi-VN");

        response.StatusCode.ShouldBe(HttpStatusCode.OK);
        response.Headers.ETag!.Tag.ShouldBe("\"vi-VN.v2\"");
        response.Headers.ETag.IsWeak.ShouldBeFalse();
        response.Headers.CacheControl!.Private.ShouldBeTrue();
        response.Headers.CacheControl.MaxAge.ShouldBe(TimeSpan.FromSeconds(60));
        root.EnumerateObject().Select(p => p.Name).ShouldBe(["locale", "version", "publishedAt", "voice", "cues"], ignoreOrder: true);
        root.GetProperty("version").GetInt32().ShouldBe(2);
        root.GetProperty("voice").GetString().ShouldBe("Giọng thử");
        var cues = root.GetProperty("cues").EnumerateArray().ToArray();
        cues.Select(c => c.GetProperty("key").GetString()).ShouldBe(["hold.done", "rest.done"]);
        var audio = cues[0].GetProperty("audio");
        audio.EnumerateObject().Select(p => p.Name).ShouldBe(["url", "expiresAt", "format", "sha256", "byteSize", "durationMs"], ignoreOrder: true);
        audio.GetProperty("format").GetString().ShouldBe("caf_ima4");
        audio.GetProperty("durationMs").GetInt32().ShouldBe(1800);
        var url = new Uri(audio.GetProperty("url").GetString()!);
        url.Host.ShouldBe("store.example.com");
        url.AbsolutePath.ShouldBe("/cali-media/voice/vi-VN/v2/hold.done.caf");
        audio.GetProperty("expiresAt").GetDateTimeOffset().ShouldBeGreaterThan(before);
        // Every URL of one response is issued at the same instant.
        cues.Select(c => c.GetProperty("audio").GetProperty("expiresAt").GetString()).Distinct().Count().ShouldBe(1);
    }

    [Fact]
    public async Task Without_object_storage_urls_are_null_and_a_version_can_be_requested()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("voice_nostore");
        await PublishAsync(cs, "vi-VN", 1, "rest.done");
        await PublishAsync(cs, "vi-VN", 2, "hold.done");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        var (response, root) = await GetAsync(client, "/v1/voice-pack?locale=vi-VN&version=1");

        response.StatusCode.ShouldBe(HttpStatusCode.OK);
        response.Headers.ETag!.Tag.ShouldBe("\"vi-VN.v1\"");
        var audio = root.GetProperty("cues")[0].GetProperty("audio");
        audio.GetProperty("url").ValueKind.ShouldBe(JsonValueKind.Null);
        audio.GetProperty("expiresAt").ValueKind.ShouldBe(JsonValueKind.Null);
    }

    [Theory]
    [InlineData("\"vi-VN.v1\"")]
    [InlineData("W/\"vi-VN.v1\"")]
    [InlineData("*")]
    public async Task Matching_if_none_match_returns_304_without_body(string ifNoneMatch)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("voice_304");
        await PublishAsync(cs, "vi-VN", 1, "rest.done");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        var (response, _) = await GetAsync(client, "/v1/voice-pack?locale=vi-VN", ifNoneMatch);

        response.StatusCode.ShouldBe(HttpStatusCode.NotModified);
        response.Headers.ETag!.Tag.ShouldBe("\"vi-VN.v1\"");
        (await response.Content.ReadAsByteArrayAsync()).ShouldBeEmpty();
    }

    [Theory]
    [InlineData("locale=en-US")]
    [InlineData("locale=vi-VN&version=9")]
    public async Task Missing_pack_returns_404_with_specific_code(string query)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("voice_404");
        await PublishAsync(cs, "vi-VN", 1, "rest.done");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        await AssertProblemAsync(await client.GetAsync(new Uri($"/v1/voice-pack?{query}", UriKind.Relative)),
            HttpStatusCode.NotFound, "voice_pack_not_found");
    }

    [Theory]
    [InlineData("")]
    [InlineData("locale=")]
    [InlineData("locale=vi")]
    [InlineData("locale=vi_VN")]
    [InlineData("locale=vi-VN&locale=en-US")]
    [InlineData("locale=vi-VN&version=0")]
    [InlineData("locale=vi-VN&version=abc")]
    public async Task Invalid_parameters_return_400(string query)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("voice_bad");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        await AssertProblemAsync(await client.GetAsync(new Uri($"/v1/voice-pack?{query}", UriKind.Relative)),
            HttpStatusCode.BadRequest, "bad_request");
    }
}
