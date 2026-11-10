using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Cali.Application.Identity;
using Cali.Infrastructure.Auth;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace Cali.Tests.Shared;

/// <summary>An RSA key pair that stands in for one of Apple's signing keys. Tests never reach the network.</summary>
internal sealed class AppleTestKey : IDisposable
{
    private readonly RSA _rsa;

    private AppleTestKey(string keyId)
    {
        KeyId = keyId;
        _rsa = RSA.Create(2048);
        PrivateKey = new RsaSecurityKey(_rsa) { KeyId = keyId };
        var publicParameters = _rsa.ExportParameters(false);
        PublicKey = new RsaSecurityKey(publicParameters) { KeyId = keyId };
        Jwk = JsonSerializer.Serialize(new Dictionary<string, string>
        {
            ["kty"] = "RSA",
            ["kid"] = keyId,
            ["use"] = "sig",
            ["alg"] = "RS256",
            ["n"] = Base64UrlEncoder.Encode(publicParameters.Modulus),
            ["e"] = Base64UrlEncoder.Encode(publicParameters.Exponent),
        });
    }

    public string KeyId { get; }

    public RsaSecurityKey PrivateKey { get; }

    public RsaSecurityKey PublicKey { get; }

    /// <summary>The key as one entry of a JWKS document.</summary>
    public string Jwk { get; }

    public static AppleTestKey Create(string keyId = "TESTKEY001") => new(keyId);

    public void Dispose() => _rsa.Dispose();
}

internal static class AppleTestTokens
{
    public const string ClientId = "com.example.cali.tests";
    public const string Subject = "001234.5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c.1122";

    /// <summary>A JWKS document with the given keys.</summary>
    public static string Jwks(params AppleTestKey[] keys) => $$"""{"keys":[{{string.Join(",", keys.Select(k => k.Jwk))}}]}""";

    /// <summary>
    /// Mints an Apple-shaped identity token. Defaults are a valid token; each parameter breaks exactly one check.
    /// <paramref name="rawNonce"/> is the raw nonce the app sends to the API; the token carries its hex SHA-256
    /// unless <paramref name="nonceClaim"/> overrides what goes into the claim.
    /// </summary>
    public static string Mint(
        AppleTestKey key,
        DateTimeOffset now,
        string? rawNonce = "raw-nonce-0001",
        string? subject = Subject,
        string issuer = AppleIdentityOptions.Issuer,
        string audience = ClientId,
        TimeSpan? lifetime = null,
        TimeSpan? notBeforeOffset = null,
        string? nonceClaim = null,
        bool includeExpiry = true,
        string? keyIdOverride = null)
    {
        var claims = new Dictionary<string, object>();
        if (subject is not null)
        {
            claims["sub"] = subject;
        }

        var claim = nonceClaim ?? (rawNonce is null ? null : AppleNonce.ExpectedClaim(rawNonce));
        if (claim is not null)
        {
            claims["nonce"] = claim;
        }

        var credentials = new SigningCredentials(
            keyIdOverride is null ? key.PrivateKey : new RsaSecurityKey(key.PrivateKey.Rsa ?? throw new InvalidOperationException()) { KeyId = keyIdOverride },
            SecurityAlgorithms.RsaSha256);
        var lifetimeValue = lifetime ?? TimeSpan.FromMinutes(10);
        return new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }.CreateToken(new SecurityTokenDescriptor
        {
            Issuer = issuer,
            Audience = audience,
            Claims = claims,
            IssuedAt = now.UtcDateTime,
            NotBefore = notBeforeOffset is { } nbf ? now.Add(nbf).UtcDateTime : null,
            Expires = includeExpiry ? now.Add(lifetimeValue).UtcDateTime : null,
            SigningCredentials = credentials,
        });
    }

    /// <summary>A token signed with HMAC (the algorithm-confusion attack) that names an existing key id.</summary>
    public static string MintHmac(string keyId, DateTimeOffset now, string rawNonce)
    {
        var secret = new SymmetricSecurityKey(RandomNumberGenerator.GetBytes(32)) { KeyId = keyId };
        return new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }.CreateToken(new SecurityTokenDescriptor
        {
            Issuer = AppleIdentityOptions.Issuer,
            Audience = ClientId,
            Claims = new Dictionary<string, object> { ["sub"] = Subject, ["nonce"] = AppleNonce.ExpectedClaim(rawNonce) },
            Expires = now.AddMinutes(10).UtcDateTime,
            SigningCredentials = new SigningCredentials(secret, SecurityAlgorithms.HmacSha256),
        });
    }

    /// <summary>An unsigned JWT (<c>alg: none</c>) with a valid-looking payload.</summary>
    public static string MintUnsigned(string keyId, DateTimeOffset now, string rawNonce)
    {
        static string Part(object value) => Base64UrlEncoder.Encode(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(value)));
        var header = Part(new Dictionary<string, object> { ["alg"] = "none", ["kid"] = keyId });
        var payload = Part(new Dictionary<string, object>
        {
            ["iss"] = AppleIdentityOptions.Issuer,
            ["aud"] = ClientId,
            ["sub"] = Subject,
            ["nonce"] = AppleNonce.ExpectedClaim(rawNonce),
            ["exp"] = now.AddMinutes(10).ToUnixTimeSeconds(),
        });
        return $"{header}.{payload}.";
    }
}

/// <summary>Key set a test controls: what it returns, how often it was asked, and when it fails.</summary>
internal sealed class FakeAppleKeySetProvider : IAppleKeySetProvider
{
    private readonly object _gate = new();
    private IReadOnlyList<SecurityKey> _keys;
    private IReadOnlyList<SecurityKey>? _afterRefresh;

    public FakeAppleKeySetProvider(params AppleTestKey[] keys) => _keys = [.. keys.Select(k => k.PublicKey)];

    public int Calls { get; private set; }

    public int ForcedRefreshes { get; private set; }

    public bool Unavailable { get; set; }

    /// <summary>The keys a forced refresh will start returning (a key rotation at Apple).</summary>
    public void RotateOnRefresh(params AppleTestKey[] keys) => _afterRefresh = [.. keys.Select(k => k.PublicKey)];

    public Task<IReadOnlyList<SecurityKey>> GetKeysAsync(bool forceRefresh, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            Calls++;
            if (Unavailable)
            {
                throw new AppleKeysUnavailableException("test: keys unavailable");
            }

            if (forceRefresh)
            {
                ForcedRefreshes++;
                if (_afterRefresh is not null)
                {
                    _keys = _afterRefresh;
                }
            }

            return Task.FromResult(_keys);
        }
    }
}
