using Microsoft.Extensions.Logging;
using Microsoft.IdentityModel.Tokens;

namespace Cali.Infrastructure.Auth;

/// <summary>Apple's JWKS cannot be obtained (network, status, size or content); never carries a token.</summary>
public sealed class AppleKeysUnavailableException : Exception
{
    public AppleKeysUnavailableException()
    {
    }

    public AppleKeysUnavailableException(string message)
        : base(message)
    {
    }

    public AppleKeysUnavailableException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>The keys Apple signs identity tokens with. Abstracted so tests never touch the network.</summary>
public interface IAppleKeySetProvider
{
    /// <param name="forceRefresh">
    /// The caller met a key id it does not know (Apple rotated keys). The provider refetches, but at most once per
    /// <see cref="AppleKeySetOptions.MinRefreshInterval"/>, so random key ids cannot turn the endpoint into a fetch amplifier.
    /// </param>
    /// <exception cref="AppleKeysUnavailableException">No usable key set (never fetched and the fetch failed, or too old).</exception>
    Task<IReadOnlyList<SecurityKey>> GetKeysAsync(bool forceRefresh, CancellationToken cancellationToken);
}

public sealed record AppleKeySetOptions(Uri Url)
{
    public const string HttpClientName = "apple-jwks";
    public static readonly Uri DefaultUrl = new("https://appleid.apple.com/auth/keys");
    public const int MaxResponseBytes = 64 * 1024;
    public const int MaxKeys = 20;

    /// <summary>How long a fetched set is used before the next request refetches it.</summary>
    public TimeSpan CacheTtl { get; init; } = TimeSpan.FromHours(1);

    /// <summary>Minimum gap between two fetch attempts, successful or not.</summary>
    public TimeSpan MinRefreshInterval { get; init; } = TimeSpan.FromMinutes(1);

    /// <summary>When Apple cannot be reached, the last good set stays usable this long.</summary>
    public TimeSpan MaxStale { get; init; } = TimeSpan.FromHours(24);
}

/// <summary>
/// Fetches Apple's JWKS over HTTPS and caches it. A single gate serializes fetches, a failed fetch keeps serving
/// the last good set (up to <see cref="AppleKeySetOptions.MaxStale"/>), and only RS256 signing keys with a key id are kept.
/// </summary>
public sealed class HttpAppleKeySetProvider(
    IHttpClientFactory httpClients, AppleKeySetOptions options, TimeProvider time, ILogger<HttpAppleKeySetProvider> logger)
    : IAppleKeySetProvider, IDisposable
{
    private sealed record Snapshot(IReadOnlyList<SecurityKey> Keys, DateTimeOffset FetchedAt);

    private readonly SemaphoreSlim _gate = new(1, 1);
    private volatile Snapshot? _snapshot;
    private DateTimeOffset _lastAttempt = DateTimeOffset.MinValue;

    public async Task<IReadOnlyList<SecurityKey>> GetKeysAsync(bool forceRefresh, CancellationToken cancellationToken)
    {
        if (!forceRefresh && _snapshot is { } current && time.GetUtcNow() - current.FetchedAt < options.CacheTtl)
        {
            return current.Keys;
        }

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var now = time.GetUtcNow();

            // Another request may have refreshed while this one waited.
            if (!forceRefresh && _snapshot is { } refreshed && now - refreshed.FetchedAt < options.CacheTtl)
            {
                return refreshed.Keys;
            }

            if (now - _lastAttempt < options.MinRefreshInterval)
            {
                return UsableOrThrow(now, "Apple key set was fetched too recently to fetch again.");
            }

            _lastAttempt = now;
            try
            {
                var keys = await FetchAsync(cancellationToken).ConfigureAwait(false);
                _snapshot = new Snapshot(keys, now);
                return keys;
            }
            catch (AppleKeysUnavailableException e)
            {
                logger.LogWarning("Apple key set fetch failed: {Reason}", e.Message);
                return UsableOrThrow(now, e.Message);
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Dispose() => _gate.Dispose();

    private IReadOnlyList<SecurityKey> UsableOrThrow(DateTimeOffset now, string reason) =>
        _snapshot is { } snapshot && now - snapshot.FetchedAt < options.MaxStale
            ? snapshot.Keys
            : throw new AppleKeysUnavailableException(reason);

    private async Task<IReadOnlyList<SecurityKey>> FetchAsync(CancellationToken cancellationToken)
    {
        string json;
        try
        {
            var client = httpClients.CreateClient(AppleKeySetOptions.HttpClientName);
            using var response = await client.GetAsync(options.Url, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw new AppleKeysUnavailableException($"Apple key endpoint answered HTTP {(int)response.StatusCode}.");
            }

            if (response.Content.Headers.ContentLength > AppleKeySetOptions.MaxResponseBytes)
            {
                throw new AppleKeysUnavailableException("Apple key response is too large.");
            }

            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            var buffer = new byte[AppleKeySetOptions.MaxResponseBytes + 1];
            var read = 0;
            int n;
            while (read < buffer.Length && (n = await stream.ReadAsync(buffer.AsMemory(read), cancellationToken).ConfigureAwait(false)) > 0)
            {
                read += n;
            }

            if (read > AppleKeySetOptions.MaxResponseBytes)
            {
                throw new AppleKeysUnavailableException("Apple key response is too large.");
            }

            json = System.Text.Encoding.UTF8.GetString(buffer, 0, read);
        }
        catch (HttpRequestException e)
        {
            throw new AppleKeysUnavailableException("Apple key endpoint could not be reached.", e);
        }
        catch (TaskCanceledException e) when (!cancellationToken.IsCancellationRequested)
        {
            throw new AppleKeysUnavailableException("Apple key endpoint timed out.", e);
        }

        return Parse(json);
    }

    internal static IReadOnlyList<SecurityKey> Parse(string json)
    {
        JsonWebKeySet set;
        try
        {
            set = new JsonWebKeySet(json);
        }
        catch (Exception e) when (e is ArgumentException or System.Text.Json.JsonException)
        {
            throw new AppleKeysUnavailableException("Apple key response is not a JWKS.", e);
        }

        var keys = set.Keys
            .Where(k => k.Kty == JsonWebAlgorithmsKeyTypes.RSA
                        && !string.IsNullOrEmpty(k.Kid)
                        && (string.IsNullOrEmpty(k.Use) || k.Use == JsonWebKeyUseNames.Sig)
                        && (string.IsNullOrEmpty(k.Alg) || k.Alg == SecurityAlgorithms.RsaSha256))
            .Take(AppleKeySetOptions.MaxKeys)
            .Cast<SecurityKey>()
            .ToList();

        return keys.Count > 0 ? keys : throw new AppleKeysUnavailableException("Apple key response holds no RS256 signing key.");
    }
}
