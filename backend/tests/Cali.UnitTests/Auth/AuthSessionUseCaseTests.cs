using Cali.Application.Identity;
using Cali.Domain.Identity;
using Microsoft.Extensions.Time.Testing;

namespace Cali.UnitTests.Auth;

/// <summary>B4 (BE-005): the two use cases, against fakes for the validator, the store and the token issuer.</summary>
public sealed class AuthSessionUseCaseTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 9, 12, 0, 0, TimeSpan.Zero);
    private static readonly SessionLifetimes Lifetimes = new(TimeSpan.FromDays(60), TimeSpan.FromDays(180));
    private static readonly UserProfile User = new(Guid.NewGuid(), null, "Asia/Bangkok", Now.AddDays(-1));

    private readonly FakeTimeProvider _time = new(Now);
    private readonly FakeValidator _validator = new();
    private readonly FakeStore _store = new();
    private readonly FakeIssuer _issuer = new();

    private AuthenticateWithApple Apple() => new(_validator, _store, _issuer, Lifetimes, _time);

    private RefreshSession Refresh() => new(_store, _issuer, Lifetimes, _time);

    [Fact]
    public async Task Sign_in_returns_a_session_whose_refresh_token_is_stored_only_as_a_hash()
    {
        var deviceId = Guid.NewGuid();

        var result = await Apple().ExecuteAsync("identity-token-0001", "raw-nonce-0001", deviceId, CancellationToken.None);

        result.Status.ShouldBe(AuthStatus.Authenticated);
        var session = result.Session.ShouldNotBeNull();
        session.User.ShouldBe(User);
        session.AccessToken.ShouldBe($"access-for-{User.Id}");
        session.ExpiresInSeconds.ShouldBe(900);
        RefreshTokenSecret.IsWellFormed(session.RefreshToken).ShouldBeTrue();

        var stored = _store.SignIn.ShouldNotBeNull();
        stored.RefreshTokenSha256.ShouldBe(RefreshTokenSecret.Hash(session.RefreshToken));
        stored.NonceSha256.ShouldBe(AppleNonce.Hash("raw-nonce-0001"));
        stored.NonceExpiresAt.ShouldBe(Now.AddMinutes(10));
        stored.AppleSubject.ShouldBe("apple-subject-1");
        stored.DeviceId.ShouldBe(deviceId);
        stored.Now.ShouldBe(Now);
        stored.Lifetimes.ShouldBe(Lifetimes);
        _validator.LastNonce.ShouldBe("raw-nonce-0001");
    }

    [Fact]
    public async Task Sign_in_with_unreachable_keys_is_unavailable_and_touches_nothing()
    {
        _validator.Result = AppleValidation.Unavailable();

        var result = await Apple().ExecuteAsync("identity-token-0001", "raw-nonce-0001", null, CancellationToken.None);

        result.Status.ShouldBe(AuthStatus.Unavailable);
        result.Session.ShouldBeNull();
        _store.SignIn.ShouldBeNull();
    }

    [Fact]
    public async Task Sign_in_with_a_bad_token_is_unauthorized_with_the_reason_and_touches_nothing()
    {
        _validator.Result = AppleValidation.Invalid(AuthFailure.TokenAudience);

        var result = await Apple().ExecuteAsync("identity-token-0001", "raw-nonce-0001", null, CancellationToken.None);

        result.Status.ShouldBe(AuthStatus.Unauthorized);
        result.Failure.ShouldBe(AuthFailure.TokenAudience);
        result.Session.ShouldBeNull();
        _store.SignIn.ShouldBeNull();
    }

    [Theory]
    [InlineData(SignInStatus.NonceReused, AuthFailure.NonceReused)]
    [InlineData(SignInStatus.AccountUnavailable, AuthFailure.AccountUnavailable)]
    public async Task Sign_in_refused_by_the_store_is_unauthorized(SignInStatus status, AuthFailure expected)
    {
        _store.SignInOutcome = new SignInOutcome(status, null);

        var result = await Apple().ExecuteAsync("identity-token-0001", "raw-nonce-0001", null, CancellationToken.None);

        result.Status.ShouldBe(AuthStatus.Unauthorized);
        result.Failure.ShouldBe(expected);
        _issuer.Issued.ShouldBe(0);
    }

    [Fact]
    public async Task Refresh_rotates_to_a_new_token_and_stores_only_hashes()
    {
        var current = RefreshTokenSecret.Create();
        var deviceId = Guid.NewGuid();

        var result = await Refresh().ExecuteAsync(current, deviceId, CancellationToken.None);

        result.Status.ShouldBe(AuthStatus.Authenticated);
        var session = result.Session.ShouldNotBeNull();
        session.RefreshToken.ShouldNotBe(current);
        RefreshTokenSecret.IsWellFormed(session.RefreshToken).ShouldBeTrue();
        var rotation = _store.Rotation.ShouldNotBeNull();
        rotation.CurrentSha256.ShouldBe(RefreshTokenSecret.Hash(current));
        rotation.NewSha256.ShouldBe(RefreshTokenSecret.Hash(session.RefreshToken));
        rotation.DeviceId.ShouldBe(deviceId);
        rotation.Now.ShouldBe(Now);
        rotation.RefreshLifetime.ShouldBe(Lifetimes.Refresh);
        session.AccessToken.ShouldBe($"access-for-{User.Id}");
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not-a-refresh-token")]
    public async Task A_malformed_refresh_token_never_reaches_the_store(string? token)
    {
        var result = await Refresh().ExecuteAsync(token!, null, CancellationToken.None);

        result.Status.ShouldBe(AuthStatus.Unauthorized);
        result.Failure.ShouldBe(AuthFailure.RefreshMalformed);
        _store.Rotation.ShouldBeNull();
    }

    [Theory]
    [InlineData(RotationStatus.Unknown, AuthFailure.RefreshUnknown)]
    [InlineData(RotationStatus.Reused, AuthFailure.RefreshReused)]
    [InlineData(RotationStatus.Expired, AuthFailure.RefreshExpired)]
    [InlineData(RotationStatus.Revoked, AuthFailure.RefreshRevoked)]
    [InlineData(RotationStatus.DeviceMismatch, AuthFailure.RefreshDeviceMismatch)]
    [InlineData(RotationStatus.UserUnavailable, AuthFailure.AccountUnavailable)]
    public async Task Every_refused_rotation_is_unauthorized_and_issues_nothing(RotationStatus status, AuthFailure expected)
    {
        _store.RotationOutcome = new RotationOutcome(status, null);

        var result = await Refresh().ExecuteAsync(RefreshTokenSecret.Create(), null, CancellationToken.None);

        result.Status.ShouldBe(AuthStatus.Unauthorized);
        result.Failure.ShouldBe(expected);
        result.Session.ShouldBeNull();
        _issuer.Issued.ShouldBe(0);
    }

    private sealed class FakeValidator : IAppleIdentityTokenValidator
    {
        public AppleValidation Result { get; set; } = AppleValidation.Valid(new AppleIdentity("apple-subject-1", Now.AddMinutes(10)));

        public string? LastNonce { get; private set; }

        public Task<AppleValidation> ValidateAsync(string identityToken, string nonce, CancellationToken cancellationToken)
        {
            LastNonce = nonce;
            return Task.FromResult(Result);
        }
    }

    private sealed class FakeStore : IAuthStore
    {
        public SignInOutcome SignInOutcome { get; set; } = new(SignInStatus.SignedIn, User);

        public RotationOutcome RotationOutcome { get; set; } = new(RotationStatus.Rotated, User);

        public SignInRecord? SignIn { get; private set; }

        public RotationRecord? Rotation { get; private set; }

        public Task<SignInOutcome> SignInWithAppleAsync(SignInRecord record, CancellationToken cancellationToken)
        {
            SignIn = record;
            return Task.FromResult(SignInOutcome);
        }

        public Task<RotationOutcome> RotateAsync(RotationRecord record, CancellationToken cancellationToken)
        {
            Rotation = record;
            return Task.FromResult(RotationOutcome);
        }
    }

    private sealed class FakeIssuer : IAccessTokenIssuer
    {
        public int Issued { get; private set; }

        public IssuedAccessToken Issue(Guid userId)
        {
            Issued++;
            return new IssuedAccessToken($"access-for-{userId}", 900);
        }
    }
}
