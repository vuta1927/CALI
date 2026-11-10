using Cali.Domain.Identity;

namespace Cali.Application.Identity;

/// <summary>
/// Why an authentication attempt was refused. Only ever logged (as the enum name) and never sent to the client:
/// every refusal is the same 401, so a caller cannot probe which check failed (docs/11 §2, ADR-071).
/// </summary>
public enum AuthFailure
{
    // Apple identity token.
    TokenMalformed,
    TokenAlgorithm,
    TokenUnknownKey,
    TokenSignature,
    TokenIssuer,
    TokenAudience,
    TokenExpired,
    TokenNotYetValid,
    TokenNonceMissing,
    TokenNonceMismatch,
    TokenSubjectInvalid,
    NonceReused,
    AccountUnavailable,

    // Refresh token.
    RefreshMalformed,
    RefreshUnknown,
    RefreshReused,
    RefreshExpired,
    RefreshRevoked,
    RefreshDeviceMismatch,
}

public enum AppleValidationStatus
{
    Valid,
    Invalid,

    /// <summary>Apple's keys cannot be obtained, or sign-in is not configured: a server-side problem, not a bad token.</summary>
    Unavailable,
}

/// <summary>The verified claims of an Apple identity token that the server uses.</summary>
/// <param name="Subject">Apple's stable user identifier (<c>sub</c>).</param>
/// <param name="ExpiresAt">Token expiry; a nonce is remembered until then.</param>
public sealed record AppleIdentity(string Subject, DateTimeOffset ExpiresAt);

public sealed record AppleValidation(AppleValidationStatus Status, AppleIdentity? Identity, AuthFailure? Failure)
{
    public static AppleValidation Valid(AppleIdentity identity) => new(AppleValidationStatus.Valid, identity, null);

    public static AppleValidation Invalid(AuthFailure failure) => new(AppleValidationStatus.Invalid, null, failure);

    public static AppleValidation Unavailable() => new(AppleValidationStatus.Unavailable, null, null);
}

/// <summary>Verifies a Sign in with Apple identity token (issuer, audience, signature, lifetime, nonce).</summary>
public interface IAppleIdentityTokenValidator
{
    /// <param name="identityToken">The JWT Apple issued to the app.</param>
    /// <param name="nonce">The raw nonce the app sent; the token must carry its lowercase hex SHA-256 (<see cref="AppleNonce"/>).</param>
    Task<AppleValidation> ValidateAsync(string identityToken, string nonce, CancellationToken cancellationToken);
}

public sealed record IssuedAccessToken(string Token, int ExpiresInSeconds);

public interface IAccessTokenIssuer
{
    IssuedAccessToken Issue(Guid userId);
}

/// <param name="Refresh">Lifetime of one refresh token (sliding: every rotation starts a new one).</param>
/// <param name="Family">Absolute cap since sign-in; after this the user signs in with Apple again.</param>
public sealed record SessionLifetimes(TimeSpan Refresh, TimeSpan Family);

public sealed record SignInRecord(
    string AppleSubject,
    byte[] NonceSha256,
    DateTimeOffset NonceExpiresAt,
    Guid? DeviceId,
    byte[] RefreshTokenSha256,
    DateTimeOffset Now,
    SessionLifetimes Lifetimes);

public enum SignInStatus
{
    SignedIn,

    /// <summary>The nonce was already used for a sign-in: the identity token is being replayed.</summary>
    NonceReused,

    /// <summary>The Apple subject belongs to a deleted account.</summary>
    AccountUnavailable,
}

public sealed record SignInOutcome(SignInStatus Status, UserProfile? User);

public sealed record RotationRecord(
    byte[] CurrentSha256,
    byte[] NewSha256,
    Guid? DeviceId,
    DateTimeOffset Now,
    TimeSpan RefreshLifetime);

public enum RotationStatus
{
    Rotated,
    Unknown,

    /// <summary>A refresh token that was already rotated was presented again; its whole family is now revoked.</summary>
    Reused,
    Expired,
    Revoked,
    DeviceMismatch,

    /// <summary>The user was deleted; the family is revoked.</summary>
    UserUnavailable,
}

public sealed record RotationOutcome(RotationStatus Status, UserProfile? User);

/// <summary>Transactional storage of users created by Apple sign-in, single-use nonces and refresh token families.</summary>
public interface IAuthStore
{
    /// <summary>
    /// One transaction: consume the nonce, find or create the user for the Apple subject, and start a refresh token family
    /// holding the first token. Concurrent first sign-ins for the same subject end up on one user.
    /// </summary>
    Task<SignInOutcome> SignInWithAppleAsync(SignInRecord record, CancellationToken cancellationToken);

    /// <summary>
    /// One transaction under row locks on the token and its family: mark the presented token used and add the next one.
    /// Presenting a token that is already used revokes the whole family and commits that revocation.
    /// </summary>
    Task<RotationOutcome> RotateAsync(RotationRecord record, CancellationToken cancellationToken);
}

public sealed record AuthSession(string AccessToken, string RefreshToken, int ExpiresInSeconds, UserProfile User);

public enum AuthStatus
{
    Authenticated,
    Unauthorized,
    Unavailable,
}

public sealed record AuthResult(AuthStatus Status, AuthSession? Session, AuthFailure? Failure)
{
    public static AuthResult Authenticated(AuthSession session) => new(AuthStatus.Authenticated, session, null);

    public static AuthResult Unauthorized(AuthFailure failure) => new(AuthStatus.Unauthorized, null, failure);

    public static AuthResult Unavailable() => new(AuthStatus.Unavailable, null, null);
}
