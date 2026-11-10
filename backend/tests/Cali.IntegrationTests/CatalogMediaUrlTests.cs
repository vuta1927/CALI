using System.Globalization;
using System.Net;
using System.Text.Json;
using Cali.IntegrationTests.Infrastructure;
using static Cali.IntegrationTests.CatalogEndpointTests;

namespace Cali.IntegrationTests;

/// <summary>
/// BE-006 (ADR-072): signed media URLs in GET /v1/exercises and /v1/exercises/{id}. The endpoint below is never
/// contacted here (signing is local); <see cref="S3CompatibleStoreTests"/> checks the URLs against a real server.
/// </summary>
[Collection(PostgresCollection.Name)]
public sealed class CatalogMediaUrlTests(PostgresFixture postgres)
{
    private const string AccessKeyId = "AKIAINTEGRATION";
    private const string Secret = "integration-test-secret-value-123";

    private static CaliApiFactory Factory(string connectionString, int? lifetimeSeconds = null)
    {
        var settings = new Dictionary<string, string?>
        {
            ["ConnectionStrings:Cali"] = connectionString,
            ["Media:Storage:Endpoint"] = "https://store.example.com",
            ["Media:Storage:Bucket"] = "cali-media",
            ["Media:Storage:AccessKeyId"] = AccessKeyId,
            ["Media:Storage:SecretAccessKey"] = Secret,
        };
        if (lifetimeSeconds is { } seconds)
        {
            settings["Media:UrlLifetimeSeconds"] = seconds.ToString(CultureInfo.InvariantCulture);
        }

        return new CaliApiFactory("Development", settings);
    }

    private const string InsertMedia = """
        INSERT INTO exercise_media (id, exercise_id, kind, content_version, storage_key, mime_type, sha256, size_bytes, license, is_public, reviewed_at)
        VALUES ($1, $2, $3, $4, $5, 'image/webp', $6, 1024, 'CC-BY-4.0', $7, CASE WHEN $8 THEN now() END)
        """;

    private static Task AddMediaAsync(string cs, Guid exerciseId, string kind, int version, string key, bool isPublic = true, bool reviewed = true) =>
        ExecuteAsync(cs, InsertMedia, Guid.NewGuid(), exerciseId, kind, version, key, new string('a', 64), isPublic, reviewed);

    private static async Task<JsonElement> GetJsonAsync(HttpClient client, string url)
    {
        var response = await client.GetAsync(new Uri(url, UriKind.Relative));
        var body = await response.Content.ReadAsStringAsync();
        response.StatusCode.ShouldBe(HttpStatusCode.OK, body);
        response.Headers.CacheControl!.NoStore.ShouldBeTrue();
        using var document = JsonDocument.Parse(body);
        return document.RootElement.Clone();
    }

    private static void AssertSignedFor(JsonElement media, string expectedPath, int lifetimeSeconds, DateTimeOffset before, DateTimeOffset after)
    {
        var url = new Uri(media.GetProperty("url").GetString()!);
        url.Scheme.ShouldBe("https");
        url.Host.ShouldBe("store.example.com");
        url.AbsolutePath.ShouldBe(expectedPath);
        url.Query.ShouldContain($"X-Amz-Expires={lifetimeSeconds}");
        url.Query.ShouldContain($"X-Amz-Credential={AccessKeyId}%2F");
        var expiresAt = media.GetProperty("urlExpiresAt").GetDateTimeOffset();
        expiresAt.ShouldBeGreaterThanOrEqualTo(before.AddSeconds(lifetimeSeconds - 1));
        expiresAt.ShouldBeLessThanOrEqualTo(after.AddSeconds(lifetimeSeconds + 1));
    }

    [Fact]
    public async Task Public_reviewed_media_gets_a_signed_url_that_expires_with_urlExpiresAt_in_detail_and_list()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("cat_signed");
        var id = await InsertExerciseAsync(cs, "ex-signed", "Signed", "static_hold");
        await AddMediaAsync(cs, id, "thumbnail", 1, "media/thumb 1.webp");
        await AddMediaAsync(cs, id, "poster", 3, "media/poster.webp");
        await AddMediaAsync(cs, id, "preview", 1, "private/p.webp", isPublic: false);
        await AddMediaAsync(cs, id, "tutorial", 1, "unreviewed/u.webp", reviewed: false);
        var hidden = await InsertExerciseAsync(cs, "ex-hidden", "Hidden", "reps", published: false);
        await AddMediaAsync(cs, hidden, "poster", 1, "hidden/h.webp");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        var before = DateTimeOffset.UtcNow;
        var detail = await GetJsonAsync(client, $"/v1/exercises/{id}");
        var list = await GetJsonAsync(client, "/v1/exercises?limit=100");
        var after = DateTimeOffset.UtcNow;

        foreach (var exercise in new[] { detail, list.GetProperty("items").EnumerateArray().Single() })
        {
            var media = exercise.GetProperty("media").EnumerateArray().OrderBy(m => m.GetProperty("kind").GetString(), StringComparer.Ordinal).ToArray();
            media.Select(m => m.GetProperty("kind").GetString()).ShouldBe(["poster", "thumbnail"]);
            AssertSignedFor(media[0], "/cali-media/media/poster.webp", 900, before, after);
            AssertSignedFor(media[1], "/cali-media/media/thumb%201.webp", 900, before, after);
            // One issue time per response: every URL of the response expires at the same instant.
            media[0].GetProperty("urlExpiresAt").GetDateTimeOffset().ShouldBe(media[1].GetProperty("urlExpiresAt").GetDateTimeOffset());
        }

        // Neither the credential, nor keys of media that is not public and reviewed, nor a storage key field.
        var raw = detail.GetRawText() + list.GetRawText();
        raw.ShouldNotContain(Secret);
        raw.ShouldNotContain("private/");
        raw.ShouldNotContain("unreviewed/");
        raw.ShouldNotContain("hidden/");
        raw.ShouldNotContain("storageKey", Case.Insensitive);
        raw.ShouldNotContain("storage_key", Case.Insensitive);
    }

    [Fact]
    public async Task The_lifetime_is_configurable_and_reported_in_the_url_and_urlExpiresAt()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("cat_ttl");
        var id = await InsertExerciseAsync(cs, "ex-ttl", "Ttl");
        await AddMediaAsync(cs, id, "poster", 1, "media/poster.webp");
        await using var factory = Factory(cs, lifetimeSeconds: 120);
        using var client = factory.CreateClient();

        var before = DateTimeOffset.UtcNow;
        var detail = await GetJsonAsync(client, $"/v1/exercises/{id}");
        var after = DateTimeOffset.UtcNow;

        AssertSignedFor(detail.GetProperty("media")[0], "/cali-media/media/poster.webp", 120, before, after);
    }

    [Fact]
    public async Task Every_response_is_fresh_so_a_second_request_gets_a_new_signature_not_a_cached_one()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("cat_fresh");
        var id = await InsertExerciseAsync(cs, "ex-fresh", "Fresh");
        await AddMediaAsync(cs, id, "poster", 1, "media/poster.webp");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        var first = (await GetJsonAsync(client, $"/v1/exercises/{id}")).GetProperty("media")[0];
        await Task.Delay(TimeSpan.FromMilliseconds(1100));
        var second = (await GetJsonAsync(client, $"/v1/exercises/{id}")).GetProperty("media")[0];

        second.GetProperty("urlExpiresAt").GetDateTimeOffset().ShouldBeGreaterThan(first.GetProperty("urlExpiresAt").GetDateTimeOffset());
        second.GetProperty("url").GetString().ShouldNotBe(first.GetProperty("url").GetString());
    }

    [Fact]
    public async Task Catalog_responses_are_never_cacheable_because_their_urls_expire()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("cat_nostore");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        foreach (var url in new[] { "/v1/exercises", "/v1/exercises?limit=0", $"/v1/exercises/{Guid.NewGuid()}" })
        {
            using var response = await client.GetAsync(new Uri(url, UriKind.Relative));
            response.Headers.CacheControl.ShouldNotBeNull(url);
            response.Headers.CacheControl.NoStore.ShouldBeTrue(url);
        }
    }

    [Fact]
    public async Task A_media_row_with_a_key_the_server_will_not_sign_degrades_to_no_url_without_failing_the_page()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("cat_badkey");
        var id = await InsertExerciseAsync(cs, "ex-badkey", "Bad key");
        await AddMediaAsync(cs, id, "thumbnail", 1, "media/ok.webp");
        await AddMediaAsync(cs, id, "poster", 1, "../escape/poster.webp");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        var detail = await GetJsonAsync(client, $"/v1/exercises/{id}");

        var media = detail.GetProperty("media").EnumerateArray().ToDictionary(m => m.GetProperty("kind").GetString()!);
        media["thumbnail"].GetProperty("url").ValueKind.ShouldBe(JsonValueKind.String);
        media["poster"].GetProperty("url").ValueKind.ShouldBe(JsonValueKind.Null);
        media["poster"].GetProperty("urlExpiresAt").ValueKind.ShouldBe(JsonValueKind.Null);
        detail.GetRawText().ShouldNotContain("escape");
    }

    [Fact]
    public async Task Without_object_storage_in_development_url_and_urlExpiresAt_stay_null()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("cat_nostore_dev");
        var id = await InsertExerciseAsync(cs, "ex-nostorage", "No storage");
        await AddMediaAsync(cs, id, "poster", 1, "media/poster.webp");
        await using var factory = new CaliApiFactory("Development", new Dictionary<string, string?> { ["ConnectionStrings:Cali"] = cs });
        using var client = factory.CreateClient();

        var media = (await GetJsonAsync(client, $"/v1/exercises/{id}")).GetProperty("media")[0];

        media.GetProperty("url").ValueKind.ShouldBe(JsonValueKind.Null);
        media.GetProperty("urlExpiresAt").ValueKind.ShouldBe(JsonValueKind.Null);
    }
}
