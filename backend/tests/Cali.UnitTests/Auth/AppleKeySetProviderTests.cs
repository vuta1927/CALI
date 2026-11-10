using System.Net;
using System.Text;
using Cali.Infrastructure.Auth;
using Cali.Tests.Shared;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Time.Testing;

namespace Cali.UnitTests.Auth;

/// <summary>B4 (BE-005): fetching, caching and refreshing Apple's JWKS without any network.</summary>
public sealed class AppleKeySetProviderTests : IDisposable
{
    private static readonly Uri Url = new("https://keys.example.test/auth/keys");

    private readonly AppleTestKey _key = AppleTestKey.Create("KID-A");
    private readonly AppleTestKey _next = AppleTestKey.Create("KID-B");
    private readonly FakeTimeProvider _time = new(new DateTimeOffset(2026, 11, 9, 12, 0, 0, TimeSpan.Zero));
    private readonly ScriptedHandler _handler = new();

    public void Dispose()
    {
        _key.Dispose();
        _next.Dispose();
        _handler.Dispose();
    }

    private HttpAppleKeySetProvider Provider(AppleKeySetOptions? options = null) =>
        new(new SingleClientFactory(_handler), options ?? new AppleKeySetOptions(Url), _time, NullLogger<HttpAppleKeySetProvider>.Instance);

    [Fact]
    public async Task Keys_are_cached_until_the_ttl_expires()
    {
        _handler.Respond(AppleTestTokens.Jwks(_key));
        using var provider = Provider();

        (await provider.GetKeysAsync(false, CancellationToken.None)).Select(k => k.KeyId).ShouldBe(["KID-A"]);
        await provider.GetKeysAsync(false, CancellationToken.None);
        _time.Advance(TimeSpan.FromMinutes(59));
        await provider.GetKeysAsync(false, CancellationToken.None);
        _handler.Requests.ShouldBe(1);

        _handler.Respond(AppleTestTokens.Jwks(_key, _next));
        _time.Advance(TimeSpan.FromMinutes(2));
        (await provider.GetKeysAsync(false, CancellationToken.None)).Select(k => k.KeyId).ShouldBe(["KID-A", "KID-B"]);
        _handler.Requests.ShouldBe(2);
    }

    [Fact]
    public async Task A_forced_refresh_refetches_but_at_most_once_per_interval()
    {
        _handler.Respond(AppleTestTokens.Jwks(_key));
        using var provider = Provider();
        await provider.GetKeysAsync(false, CancellationToken.None);

        // Right after the first fetch: a flood of "unknown kid" requests must not refetch.
        for (var i = 0; i < 5; i++)
        {
            await provider.GetKeysAsync(true, CancellationToken.None);
        }

        _handler.Requests.ShouldBe(1);

        _handler.Respond(AppleTestTokens.Jwks(_key, _next));
        _time.Advance(TimeSpan.FromMinutes(2));
        (await provider.GetKeysAsync(true, CancellationToken.None)).Select(k => k.KeyId).ShouldBe(["KID-A", "KID-B"]);
        await provider.GetKeysAsync(true, CancellationToken.None);
        _handler.Requests.ShouldBe(2);
    }

    [Fact]
    public async Task Concurrent_first_requests_share_one_fetch()
    {
        _handler.Respond(AppleTestTokens.Jwks(_key));
        using var provider = Provider();

        await Task.WhenAll(Enumerable.Range(0, 20).Select(_ => provider.GetKeysAsync(false, CancellationToken.None)));

        _handler.Requests.ShouldBe(1);
    }

    [Fact]
    public async Task A_failed_refetch_keeps_serving_the_last_good_keys_until_they_are_too_old()
    {
        _handler.Respond(AppleTestTokens.Jwks(_key));
        using var provider = Provider();
        await provider.GetKeysAsync(false, CancellationToken.None);

        _handler.Fail(HttpStatusCode.BadGateway);
        _time.Advance(TimeSpan.FromHours(2));
        (await provider.GetKeysAsync(false, CancellationToken.None)).Select(k => k.KeyId).ShouldBe(["KID-A"]);

        _time.Advance(TimeSpan.FromHours(23));
        await Should.ThrowAsync<AppleKeysUnavailableException>(() => provider.GetKeysAsync(false, CancellationToken.None));
    }

    [Fact]
    public async Task Without_any_good_keys_a_failure_is_unavailable_and_a_retry_waits_for_the_interval()
    {
        _handler.Fail(HttpStatusCode.ServiceUnavailable);
        using var provider = Provider();

        await Should.ThrowAsync<AppleKeysUnavailableException>(() => provider.GetKeysAsync(false, CancellationToken.None));
        await Should.ThrowAsync<AppleKeysUnavailableException>(() => provider.GetKeysAsync(false, CancellationToken.None));
        _handler.Requests.ShouldBe(1);

        _handler.Respond(AppleTestTokens.Jwks(_key));
        _time.Advance(TimeSpan.FromMinutes(2));
        (await provider.GetKeysAsync(false, CancellationToken.None)).ShouldNotBeEmpty();
        _handler.Requests.ShouldBe(2);
    }

    [Fact]
    public async Task A_network_error_is_unavailable()
    {
        _handler.Throw(new HttpRequestException("boom"));
        using var provider = Provider();

        await Should.ThrowAsync<AppleKeysUnavailableException>(() => provider.GetKeysAsync(false, CancellationToken.None));
    }

    [Fact]
    public async Task An_oversized_response_is_unavailable()
    {
        _handler.Respond(new string(' ', AppleKeySetOptions.MaxResponseBytes + 10) + AppleTestTokens.Jwks(_key));
        using var provider = Provider();

        await Should.ThrowAsync<AppleKeysUnavailableException>(() => provider.GetKeysAsync(false, CancellationToken.None));
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("{}")]
    [InlineData("{\"keys\":[]}")]
    [InlineData("{\"keys\":[{\"kty\":\"EC\",\"kid\":\"x\",\"crv\":\"P-256\",\"x\":\"AQ\",\"y\":\"AQ\"}]}")]
    [InlineData("{\"keys\":[{\"kty\":\"RSA\",\"n\":\"AQAB\",\"e\":\"AQAB\"}]}")]
    public async Task Content_without_a_usable_RSA_signing_key_is_unavailable(string body)
    {
        _handler.Respond(body);
        using var provider = Provider();

        await Should.ThrowAsync<AppleKeysUnavailableException>(() => provider.GetKeysAsync(false, CancellationToken.None));
    }

    [Fact]
    public void Only_RS256_signing_keys_with_a_key_id_are_kept()
    {
        var jwks = $$"""
            {"keys":[
              {{_key.Jwk}},
              {"kty":"RSA","kid":"enc","use":"enc","alg":"RS256","n":"AQAB","e":"AQAB"},
              {"kty":"RSA","kid":"ps","use":"sig","alg":"PS256","n":"AQAB","e":"AQAB"},
              {"kty":"EC","kid":"ec","use":"sig","crv":"P-256","x":"AQ","y":"AQ"}
            ]}
            """;

        HttpAppleKeySetProvider.Parse(jwks).Select(k => k.KeyId).ShouldBe(["KID-A"]);
    }

    private sealed class ScriptedHandler : HttpMessageHandler
    {
        private Func<HttpResponseMessage> _next = () => new HttpResponseMessage(HttpStatusCode.NotFound);

        public int Requests { get; private set; }

        public void Respond(string body) =>
            _next = () => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

        public void Fail(HttpStatusCode status) => _next = () => new HttpResponseMessage(status);

        public void Throw(Exception exception) => _next = () => throw exception;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests++;
            request.RequestUri.ShouldBe(Url);
            return Task.FromResult(_next());
        }
    }

    private sealed class SingleClientFactory(HttpMessageHandler handler) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name)
        {
            name.ShouldBe(AppleKeySetOptions.HttpClientName);
            return new HttpClient(handler, disposeHandler: false);
        }
    }
}
