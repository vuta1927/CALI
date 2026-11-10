using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using Cali.Infrastructure.Media;
using Cali.IntegrationTests.Infrastructure;
using DotNet.Testcontainers.Builders;
using static Cali.IntegrationTests.CatalogEndpointTests;

namespace Cali.IntegrationTests;

/// <summary>
/// BE-006 (ADR-072): the URLs the catalog hands out are accepted by a real S3-compatible server (Scality
/// CloudServer, in memory), and tampered, expired or unsigned requests are refused. The unit tests only prove the
/// algorithm against AWS's published example; this proves path-style addressing, key encoding and the host header.
/// </summary>
[Collection(PostgresCollection.Name)]
public sealed class S3CompatibleStoreTests(PostgresFixture postgres)
{
    // Pinned by digest: the `latest` tag of this project is frozen, and a digest cannot change under us.
    private const string StoreImage = "zenko/cloudserver@sha256:b53e57829cf7df357323e60a19c9f98d2218f1b7ccb1d7cea5761a5a227a9ee3";
    private const string AccessKeyId = "cali-test-key";
    private const string Secret = "cali-test-secret-value";
    private const string Region = "us-east-1";
    private const string Bucket = "cali-media";
    private const string Key = "media/ex 1/póster+a=b.webp";

    private static readonly HttpClient Http = new();

    private static Uri PresignedPut(Uri origin, string path, string secret = Secret) =>
        S3PresignedUrlSigner.Presign("PUT", origin, path, Region, AccessKeyId, secret, DateTimeOffset.UtcNow, 300);

    private static async Task<HttpResponseMessage> PutAsync(Uri origin, string path, byte[] body)
    {
        // The first requests can race the server's startup: retry until it answers at all.
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                return await Http.PutAsync(PresignedPut(origin, path), new ByteArrayContent(body));
            }
            catch (HttpRequestException) when (attempt < 30)
            {
                await Task.Delay(500);
            }
        }
    }

    [Fact]
    public async Task Catalog_urls_are_accepted_by_a_real_S3_compatible_server_and_tampered_expired_or_unsigned_ones_are_refused()
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

        // Seed the bucket and one object through presigned PUTs made with the same signing code.
        (await PutAsync(origin, $"/{Bucket}", [])).StatusCode.ShouldBe(HttpStatusCode.OK);
        var bytes = RandomNumberGenerator.GetBytes(64 * 1024);
        var keyPath = new S3PresignedUrlSigner(Options(origin, Secret)).Sign(Key, DateTimeOffset.UtcNow)!.Url.AbsolutePath;
        keyPath.ShouldBe($"/{Bucket}/media/ex%201/p%C3%B3ster%2Ba%3Db.webp");
        using (var put = await PutAsync(origin, keyPath, bytes))
        {
            put.StatusCode.ShouldBe(HttpStatusCode.OK, await put.Content.ReadAsStringAsync());
        }

        var cs = await postgres.CreateMigratedDatabaseAsync("s3_e2e");
        var id = await InsertExerciseAsync(cs, "ex-e2e", "End to end", "static_hold");
        await ExecuteAsync(cs, """
            INSERT INTO exercise_media (id, exercise_id, kind, content_version, storage_key, mime_type, sha256, size_bytes, license, is_public, reviewed_at)
            VALUES ($1, $2, 'poster', 1, $3, 'image/webp', $4, $5, 'CC-BY-4.0', true, now())
            """, Guid.NewGuid(), id, Key, Convert.ToHexStringLower(SHA256.HashData(bytes)), (long)bytes.Length);

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
        using var detail = JsonDocument.Parse(await api.GetStringAsync(new Uri($"/v1/exercises/{id}", UriKind.Relative)));
        var media = detail.RootElement.GetProperty("media")[0];
        var url = media.GetProperty("url").GetString()!;

        // 1. The URL from the catalog downloads the exact bytes whose hash the catalog reported.
        using (var ok = await Http.GetAsync(url))
        {
            ok.StatusCode.ShouldBe(HttpStatusCode.OK);
            var body = await ok.Content.ReadAsByteArrayAsync();
            body.ShouldBe(bytes);
            Convert.ToHexStringLower(SHA256.HashData(body)).ShouldBe(media.GetProperty("sha256").GetString());
        }

        // 2. Range requests (AVPlayer streams video this way) work on the same URL.
        using (var range = new HttpRequestMessage(HttpMethod.Get, url) { Headers = { Range = new RangeHeaderValue(0, 99) } })
        using (var partial = await Http.SendAsync(range))
        {
            partial.StatusCode.ShouldBe(HttpStatusCode.PartialContent);
            (await partial.Content.ReadAsByteArrayAsync()).ShouldBe(bytes[..100]);
        }

        // 3. Anything that changes a signed part, or lacks the signature, is refused.
        var refused = new Dictionary<string, string>
        {
            ["another key"] = url.Replace("ex%201", "ex%202", StringComparison.Ordinal),
            ["longer expiry"] = url.Replace("X-Amz-Expires=900", "X-Amz-Expires=3600", StringComparison.Ordinal),
            ["no signature"] = url[..url.IndexOf("&X-Amz-Signature=", StringComparison.Ordinal)],
            ["no query at all"] = url[..url.IndexOf('?', StringComparison.Ordinal)],
        };
        foreach (var (name, tampered) in refused)
        {
            tampered.ShouldNotBe(url, name);
            using var response = await Http.GetAsync(tampered);
            // 403 for a bad or missing signature; this server answers 400 when the signature parameter is absent
            // from an otherwise presigned query. Either way the object is not served.
            new[] { HttpStatusCode.Forbidden, HttpStatusCode.BadRequest }.ShouldContain(response.StatusCode, name);
        }

        // 4. A URL signed long ago has expired; one signed with another secret is no better.
        var path = new Uri(url).AbsolutePath;
        var expired = S3PresignedUrlSigner.Presign("GET", origin, path, Region, AccessKeyId, Secret, DateTimeOffset.UtcNow.AddHours(-2), 60);
        var wrongSecret = S3PresignedUrlSigner.Presign("GET", origin, path, Region, AccessKeyId, "not-the-secret", DateTimeOffset.UtcNow, 60);
        using (var response = await Http.GetAsync(expired))
        {
            response.StatusCode.ShouldBe(HttpStatusCode.Forbidden, "expired");
        }

        using (var response = await Http.GetAsync(wrongSecret))
        {
            response.StatusCode.ShouldBe(HttpStatusCode.Forbidden, "wrong secret");
        }

        // The same URL signed correctly just now still works: the refusals above are about the signature, not the object.
        var fresh = S3PresignedUrlSigner.Presign("GET", origin, path, Region, AccessKeyId, Secret, DateTimeOffset.UtcNow, 60);
        using (var response = await Http.GetAsync(fresh))
        {
            response.StatusCode.ShouldBe(HttpStatusCode.OK);
        }
    }

    private static S3StorageOptions Options(Uri origin, string secret) => new()
    {
        Endpoint = new Uri(origin.GetLeftPart(UriPartial.Authority)),
        Bucket = Bucket,
        Region = Region,
        AccessKeyId = AccessKeyId,
        SecretAccessKey = secret,
        Lifetime = TimeSpan.FromMinutes(15),
    };
}
