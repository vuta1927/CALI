using Cali.Infrastructure.Auth;
using Microsoft.IdentityModel.Tokens;

namespace Cali.Api.Auth;

public sealed record TrustedIssuer(string Issuer, IReadOnlyList<SecurityKey> SigningKeys);

/// <summary>
/// The set of (issuer, keys) pairs the API accepts. Keys are bound to their issuer: a token is only
/// checked against keys of the issuer it claims, so a dev key can never validate a non-dev issuer.
/// </summary>
public static class TrustedIssuers
{
    /// <param name="accessTokens">
    /// When given, the access-token issuer minted after Sign in with Apple (ADR-071) is trusted in every environment.
    /// </param>
    public static IReadOnlyList<TrustedIssuer> Build(
        IConfiguration configuration, IHostEnvironment environment, ILogger logger, AuthTokenSettings? accessTokens = null)
    {
        var issuers = new List<TrustedIssuer>();

        // ADR-015: the dev issuer exists ONLY in Development. In any other environment it is never
        // registered, so dev tokens fail validation even if a dev key is present in configuration.
        if (environment.IsDevelopment())
        {
            if (DevSigningKey.TryParse(configuration[DevTokenDefaults.SigningKeyConfigKey], out var key, out var error))
            {
                issuers.Add(new TrustedIssuer(DevTokenDefaults.Issuer, [new SymmetricSecurityKey(key)]));
            }
            else
            {
                logger.LogWarning("Dev tokens disabled: {Reason}", error);
            }
        }

        // The CALI access-token issuer (POST /v1/auth/apple and /v1/auth/refresh). Its key is bound to this issuer
        // like every other key, and it is a different key from the dev one.
        if (accessTokens is not null)
        {
            issuers.Add(new TrustedIssuer(AccessTokenDefaults.Issuer, [new SymmetricSecurityKey(accessTokens.AccessTokenKey)]));
        }

        return issuers;
    }
}
