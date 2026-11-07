using System.Security.Claims;
using System.Security.Cryptography;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace Cali.Infrastructure.Auth;

/// <summary>
/// Development-only access tokens (ADR-015). The API trusts this issuer ONLY when
/// <c>ASPNETCORE_ENVIRONMENT=Development</c>; the key is supplied via env / user-secrets and never committed.
/// </summary>
public static class DevTokenDefaults
{
    public const string Issuer = "cali-dev-token";
    public const string Audience = "cali-api";

    /// <summary>Configuration key (env: <c>Auth__DevTokens__SigningKey</c>). Base64, at least <see cref="MinKeyBytes"/> bytes.</summary>
    public const string SigningKeyConfigKey = "Auth:DevTokens:SigningKey";

    public const int MinKeyBytes = 32;
    public static readonly TimeSpan MaxLifetime = TimeSpan.FromDays(30);
    public static readonly TimeSpan DefaultLifetime = TimeSpan.FromHours(8);
}

public static class DevSigningKey
{
    /// <summary>Creates a new random 256-bit key, base64 encoded.</summary>
    public static string Generate() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(DevTokenDefaults.MinKeyBytes));

    public static bool TryParse(string? base64, out byte[] key, out string? error)
    {
        key = [];
        if (string.IsNullOrWhiteSpace(base64))
        {
            error = $"{DevTokenDefaults.SigningKeyConfigKey} is not configured.";
            return false;
        }

        try
        {
            key = Convert.FromBase64String(base64.Trim());
        }
        catch (FormatException)
        {
            error = $"{DevTokenDefaults.SigningKeyConfigKey} is not valid base64.";
            return false;
        }

        if (key.Length < DevTokenDefaults.MinKeyBytes)
        {
            error = $"{DevTokenDefaults.SigningKeyConfigKey} must decode to at least {DevTokenDefaults.MinKeyBytes} bytes.";
            key = [];
            return false;
        }

        error = null;
        return true;
    }
}

public static class DevTokenFactory
{
    public static string Create(Guid subject, TimeSpan lifetime, DateTimeOffset now, byte[] signingKey)
    {
        if (subject == Guid.Empty)
        {
            throw new ArgumentException("Subject must be a non-empty UUID.", nameof(subject));
        }

        if (lifetime <= TimeSpan.Zero || lifetime > DevTokenDefaults.MaxLifetime)
        {
            throw new ArgumentOutOfRangeException(nameof(lifetime), lifetime, $"Lifetime must be > 0 and <= {DevTokenDefaults.MaxLifetime}.");
        }

        ArgumentNullException.ThrowIfNull(signingKey);
        if (signingKey.Length < DevTokenDefaults.MinKeyBytes)
        {
            throw new ArgumentException($"Signing key must be at least {DevTokenDefaults.MinKeyBytes} bytes.", nameof(signingKey));
        }

        var descriptor = new SecurityTokenDescriptor
        {
            Issuer = DevTokenDefaults.Issuer,
            Audience = DevTokenDefaults.Audience,
            Subject = new ClaimsIdentity(
            [
                new Claim(JwtRegisteredClaimNames.Sub, subject.ToString("D")),
                new Claim(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString("N")),
            ]),
            IssuedAt = now.UtcDateTime,
            NotBefore = now.UtcDateTime,
            Expires = now.Add(lifetime).UtcDateTime,
            SigningCredentials = new SigningCredentials(new SymmetricSecurityKey(signingKey), SecurityAlgorithms.HmacSha256),
        };

        return new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }.CreateToken(descriptor);
    }
}
