using System.Security.Cryptography;
using System.Text;
using Cali.Application.Identity;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace Cali.Infrastructure.Auth;

/// <param name="ClientId">The app's bundle id: the identity token <c>aud</c>. Null disables Sign in with Apple.</param>
public sealed record AppleIdentityOptions(string? ClientId)
{
    public const string Issuer = "https://appleid.apple.com";
    public const int MaxSubjectLength = 255;

    /// <summary>Accepted drift between Apple's clock and ours, for <c>exp</c> and <c>nbf</c>.</summary>
    public TimeSpan ClockSkew { get; init; } = TimeSpan.FromSeconds(60);
}

/// <summary>
/// Validates a Sign in with Apple identity token: RS256 only, a key id Apple currently publishes, issuer, audience,
/// signature, expiry, not-before, the nonce, and a usable <c>sub</c>. Lifetime is checked against the injected clock.
/// </summary>
public sealed class AppleIdentityTokenValidator(IAppleKeySetProvider keys, AppleIdentityOptions options, TimeProvider time)
    : IAppleIdentityTokenValidator
{
    private readonly JsonWebTokenHandler _handler = new();

    public async Task<AppleValidation> ValidateAsync(string identityToken, string nonce, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(identityToken);
        ArgumentNullException.ThrowIfNull(nonce);
        if (string.IsNullOrWhiteSpace(options.ClientId))
        {
            return AppleValidation.Unavailable();
        }

        // Read the header before any network call, so garbage never makes the server fetch Apple's keys.
        JsonWebToken token;
        try
        {
            token = new JsonWebToken(identityToken);
        }
        catch (Exception e) when (e is ArgumentException or SecurityTokenException or FormatException or System.Text.Json.JsonException)
        {
            return AppleValidation.Invalid(AuthFailure.TokenMalformed);
        }

        if (!string.Equals(token.Alg, SecurityAlgorithms.RsaSha256, StringComparison.Ordinal))
        {
            return AppleValidation.Invalid(AuthFailure.TokenAlgorithm);
        }

        if (string.IsNullOrEmpty(token.Kid))
        {
            return AppleValidation.Invalid(AuthFailure.TokenUnknownKey);
        }

        SecurityKey? key;
        try
        {
            key = Find(await keys.GetKeysAsync(forceRefresh: false, cancellationToken).ConfigureAwait(false), token.Kid)
                  ?? Find(await keys.GetKeysAsync(forceRefresh: true, cancellationToken).ConfigureAwait(false), token.Kid);
        }
        catch (AppleKeysUnavailableException)
        {
            return AppleValidation.Unavailable();
        }

        if (key is null)
        {
            return AppleValidation.Invalid(AuthFailure.TokenUnknownKey);
        }

        var result = await _handler.ValidateTokenAsync(identityToken, new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = AppleIdentityOptions.Issuer,
            ValidateAudience = true,
            ValidAudience = options.ClientId,
            ValidateIssuerSigningKey = false,
            IssuerSigningKey = key,
            RequireSignedTokens = true,
            ValidAlgorithms = [SecurityAlgorithms.RsaSha256],
            // Lifetime is checked below against the injected clock.
            ValidateLifetime = false,
            RequireExpirationTime = false,
        }).ConfigureAwait(false);

        if (!result.IsValid)
        {
            return AppleValidation.Invalid(result.Exception switch
            {
                SecurityTokenInvalidIssuerException => AuthFailure.TokenIssuer,
                SecurityTokenInvalidAudienceException => AuthFailure.TokenAudience,
                SecurityTokenInvalidSignatureException or SecurityTokenSignatureKeyNotFoundException => AuthFailure.TokenSignature,
                _ => AuthFailure.TokenMalformed,
            });
        }

        var verified = (JsonWebToken)result.SecurityToken;
        var now = time.GetUtcNow();
        if (verified.ValidTo == DateTime.MinValue)
        {
            return AppleValidation.Invalid(AuthFailure.TokenExpired);
        }

        var expiresAt = new DateTimeOffset(DateTime.SpecifyKind(verified.ValidTo, DateTimeKind.Utc));
        if (now - options.ClockSkew >= expiresAt)
        {
            return AppleValidation.Invalid(AuthFailure.TokenExpired);
        }

        if (verified.ValidFrom != DateTime.MinValue
            && new DateTimeOffset(DateTime.SpecifyKind(verified.ValidFrom, DateTimeKind.Utc)) - options.ClockSkew > now)
        {
            return AppleValidation.Invalid(AuthFailure.TokenNotYetValid);
        }

        if (!verified.TryGetPayloadValue<string>("nonce", out var claim) || string.IsNullOrEmpty(claim))
        {
            return AppleValidation.Invalid(AuthFailure.TokenNonceMissing);
        }

        if (!CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(claim), Encoding.UTF8.GetBytes(AppleNonce.ExpectedClaim(nonce))))
        {
            return AppleValidation.Invalid(AuthFailure.TokenNonceMismatch);
        }

        var subject = verified.Subject;
        if (string.IsNullOrWhiteSpace(subject) || subject.Length > AppleIdentityOptions.MaxSubjectLength)
        {
            return AppleValidation.Invalid(AuthFailure.TokenSubjectInvalid);
        }

        return AppleValidation.Valid(new AppleIdentity(subject, expiresAt));
    }

    private static SecurityKey? Find(IReadOnlyList<SecurityKey> set, string keyId) =>
        set.FirstOrDefault(k => string.Equals(k.KeyId, keyId, StringComparison.Ordinal));
}
