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
    public static IReadOnlyList<TrustedIssuer> Build(IConfiguration configuration, IHostEnvironment environment, ILogger logger)
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

        // TODO(BE-005): register the CALI access-token issuer minted after Sign in with Apple exchange
        // (POST /v1/auth/apple). Expiry: remove this TODO when BE-005 lands; until then non-Development
        // environments trust no issuer and reject every bearer token.
        return issuers;
    }
}
