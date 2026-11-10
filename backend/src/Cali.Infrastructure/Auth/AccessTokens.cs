using System.Security.Claims;
using Cali.Application.Identity;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace Cali.Infrastructure.Auth;

public static class AccessTokenDefaults
{
    /// <summary>Issuer of the short-lived access tokens minted after Sign in with Apple (ADR-071).</summary>
    public const string Issuer = "cali-auth";

    public const int MinKeyBytes = 32;
}

/// <summary>
/// Mints the HS256 access JWT the API itself validates (<c>sub</c> = user id, no other personal data).
/// Access tokens are not stored or checked against the database per request, so a revoked session stays usable
/// until its access token expires; that is why the lifetime is short.
/// </summary>
public sealed class AccessTokenIssuer : IAccessTokenIssuer
{
    private readonly SigningCredentials _credentials;
    private readonly string _audience;
    private readonly TimeSpan _lifetime;
    private readonly TimeProvider _time;
    private readonly JsonWebTokenHandler _handler = new() { SetDefaultTimesOnTokenCreation = false };

    public AccessTokenIssuer(byte[] signingKey, string audience, TimeSpan lifetime, TimeProvider time)
    {
        ArgumentNullException.ThrowIfNull(signingKey);
        ArgumentException.ThrowIfNullOrWhiteSpace(audience);
        ArgumentNullException.ThrowIfNull(time);
        if (signingKey.Length < AccessTokenDefaults.MinKeyBytes)
        {
            throw new ArgumentException($"The access token signing key must be at least {AccessTokenDefaults.MinKeyBytes} bytes.", nameof(signingKey));
        }

        if (lifetime <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(lifetime), "Lifetime must be positive.");
        }

        _credentials = new SigningCredentials(new SymmetricSecurityKey((byte[])signingKey.Clone()), SecurityAlgorithms.HmacSha256);
        _audience = audience;
        _lifetime = lifetime;
        _time = time;
    }

    public IssuedAccessToken Issue(Guid userId)
    {
        if (userId == Guid.Empty)
        {
            throw new ArgumentException("User id must be a non-empty UUID.", nameof(userId));
        }

        var now = _time.GetUtcNow();
        var token = _handler.CreateToken(new SecurityTokenDescriptor
        {
            Issuer = AccessTokenDefaults.Issuer,
            Audience = _audience,
            Subject = new ClaimsIdentity(
            [
                new Claim(JwtRegisteredClaimNames.Sub, userId.ToString("D")),
                new Claim(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString("N")),
            ]),
            IssuedAt = now.UtcDateTime,
            NotBefore = now.UtcDateTime,
            Expires = now.Add(_lifetime).UtcDateTime,
            SigningCredentials = _credentials,
        });

        return new IssuedAccessToken(token, (int)_lifetime.TotalSeconds);
    }
}
