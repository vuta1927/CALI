namespace Cali.Application.Identity;

/// <summary>Use case behind <c>POST /v1/auth/apple</c>: exchange an Apple identity token for a CALI session.</summary>
public sealed class AuthenticateWithApple(
    IAppleIdentityTokenValidator validator,
    IAuthStore store,
    IAccessTokenIssuer accessTokens,
    SessionLifetimes lifetimes,
    TimeProvider time)
{
    public async Task<AuthResult> ExecuteAsync(string identityToken, string nonce, Guid? deviceId, CancellationToken cancellationToken)
    {
        var validation = await validator.ValidateAsync(identityToken, nonce, cancellationToken).ConfigureAwait(false);
        if (validation.Status == AppleValidationStatus.Unavailable)
        {
            return AuthResult.Unavailable();
        }

        if (validation.Status != AppleValidationStatus.Valid || validation.Identity is null)
        {
            return AuthResult.Unauthorized(validation.Failure ?? AuthFailure.TokenMalformed);
        }

        var refreshToken = RefreshTokenSecret.Create();
        var outcome = await store.SignInWithAppleAsync(
            new SignInRecord(
                validation.Identity.Subject,
                AppleNonce.Hash(nonce),
                validation.Identity.ExpiresAt,
                deviceId,
                RefreshTokenSecret.Hash(refreshToken),
                time.GetUtcNow(),
                lifetimes),
            cancellationToken).ConfigureAwait(false);

        if (outcome.Status != SignInStatus.SignedIn || outcome.User is null)
        {
            return AuthResult.Unauthorized(outcome.Status == SignInStatus.NonceReused ? AuthFailure.NonceReused : AuthFailure.AccountUnavailable);
        }

        var access = accessTokens.Issue(outcome.User.Id);
        return AuthResult.Authenticated(new AuthSession(access.Token, refreshToken, access.ExpiresInSeconds, outcome.User));
    }
}

/// <summary>Use case behind <c>POST /v1/auth/refresh</c>: rotate a refresh token (every token is single use).</summary>
public sealed class RefreshSession(
    IAuthStore store,
    IAccessTokenIssuer accessTokens,
    SessionLifetimes lifetimes,
    TimeProvider time)
{
    public async Task<AuthResult> ExecuteAsync(string refreshToken, Guid? deviceId, CancellationToken cancellationToken)
    {
        if (!RefreshTokenSecret.IsWellFormed(refreshToken))
        {
            return AuthResult.Unauthorized(AuthFailure.RefreshMalformed);
        }

        var next = RefreshTokenSecret.Create();
        var outcome = await store.RotateAsync(
            new RotationRecord(RefreshTokenSecret.Hash(refreshToken), RefreshTokenSecret.Hash(next), deviceId, time.GetUtcNow(), lifetimes.Refresh),
            cancellationToken).ConfigureAwait(false);

        if (outcome.Status != RotationStatus.Rotated || outcome.User is null)
        {
            return AuthResult.Unauthorized(outcome.Status switch
            {
                RotationStatus.Reused => AuthFailure.RefreshReused,
                RotationStatus.Expired => AuthFailure.RefreshExpired,
                RotationStatus.Revoked => AuthFailure.RefreshRevoked,
                RotationStatus.DeviceMismatch => AuthFailure.RefreshDeviceMismatch,
                RotationStatus.UserUnavailable => AuthFailure.AccountUnavailable,
                _ => AuthFailure.RefreshUnknown,
            });
        }

        var access = accessTokens.Issue(outcome.User.Id);
        return AuthResult.Authenticated(new AuthSession(access.Token, next, access.ExpiresInSeconds, outcome.User));
    }
}
