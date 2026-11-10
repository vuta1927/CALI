using Cali.Application.Identity;
using Cali.Infrastructure.Auth;
using Cali.Tests.Shared;
using Microsoft.Extensions.Time.Testing;

namespace Cali.UnitTests.Auth;

/// <summary>B4 (BE-005): Sign in with Apple identity token validation, with self-signed tokens and a fake key set.</summary>
public sealed class AppleIdentityTokenValidatorTests : IDisposable
{
    private const string Nonce = "raw-nonce-0001";
    private static readonly DateTimeOffset Start = new(2026, 11, 9, 12, 0, 0, TimeSpan.Zero);

    private readonly AppleTestKey _key = AppleTestKey.Create("KID-A");
    private readonly AppleTestKey _otherKey = AppleTestKey.Create("KID-B");
    private readonly FakeTimeProvider _time = new(Start);
    private readonly FakeAppleKeySetProvider _keys;

    public AppleIdentityTokenValidatorTests() => _keys = new FakeAppleKeySetProvider(_key);

    public void Dispose()
    {
        _key.Dispose();
        _otherKey.Dispose();
    }

    private AppleIdentityTokenValidator Validator(string? clientId = AppleTestTokens.ClientId, IAppleKeySetProvider? keys = null) =>
        new(keys ?? _keys, new AppleIdentityOptions(clientId), _time);

    private string Mint(Action<MintOptions>? configure = null)
    {
        var o = new MintOptions();
        configure?.Invoke(o);
        return AppleTestTokens.Mint(
            o.Key ?? _key, Start, o.RawNonce, o.Subject, o.Issuer, o.Audience, o.Lifetime, o.NotBeforeOffset, o.NonceClaim, o.IncludeExpiry, o.KeyId);
    }

    [Fact]
    public async Task A_valid_token_yields_the_subject_and_expiry()
    {
        var result = await Validator().ValidateAsync(Mint(), Nonce, CancellationToken.None);

        result.Status.ShouldBe(AppleValidationStatus.Valid);
        result.Identity.ShouldNotBeNull().Subject.ShouldBe(AppleTestTokens.Subject);
        result.Identity.ExpiresAt.ShouldBe(Start.AddMinutes(10));
        _keys.ForcedRefreshes.ShouldBe(0);
    }

    [Fact]
    public async Task Wrong_issuer_is_refused()
    {
        await ShouldRefuseAsync(Mint(o => o.Issuer = "https://evil.example"), AuthFailure.TokenIssuer);
    }

    [Fact]
    public async Task Wrong_audience_is_refused()
    {
        await ShouldRefuseAsync(Mint(o => o.Audience = "com.someone.else"), AuthFailure.TokenAudience);
    }

    [Fact]
    public async Task A_token_signed_by_another_key_under_a_known_key_id_is_refused()
    {
        // Same kid, different private key: the signature cannot verify against Apple's published key.
        await ShouldRefuseAsync(Mint(o =>
        {
            o.Key = _otherKey;
            o.KeyId = "KID-A";
        }), AuthFailure.TokenSignature);
    }

    [Fact]
    public async Task A_tampered_payload_is_refused()
    {
        var parts = Mint().Split('.');
        var forged = Microsoft.IdentityModel.Tokens.Base64UrlEncoder.Encode(
            System.Text.Encoding.UTF8.GetBytes($$"""{"iss":"https://appleid.apple.com","aud":"{{AppleTestTokens.ClientId}}","sub":"attacker","nonce":"{{AppleNonce.ExpectedClaim(Nonce)}}","exp":{{Start.AddMinutes(10).ToUnixTimeSeconds()}}}"""));

        await ShouldRefuseAsync($"{parts[0]}.{forged}.{parts[2]}", AuthFailure.TokenSignature);
    }

    [Fact]
    public async Task An_expired_token_is_refused_but_clock_skew_is_tolerated()
    {
        var token = Mint();

        _time.SetUtcNow(Start.AddMinutes(10).AddSeconds(59));
        (await Validator().ValidateAsync(token, Nonce, CancellationToken.None)).Status.ShouldBe(AppleValidationStatus.Valid);

        _time.SetUtcNow(Start.AddMinutes(11));
        await ShouldRefuseAsync(token, AuthFailure.TokenExpired);
    }

    [Fact]
    public async Task A_token_without_an_expiry_is_refused()
    {
        await ShouldRefuseAsync(Mint(o => o.IncludeExpiry = false), AuthFailure.TokenExpired);
    }

    [Fact]
    public async Task A_token_not_valid_yet_is_refused_beyond_the_skew()
    {
        await ShouldRefuseAsync(Mint(o => o.NotBeforeOffset = TimeSpan.FromMinutes(5)), AuthFailure.TokenNotYetValid);
        (await Validator().ValidateAsync(Mint(o => o.NotBeforeOffset = TimeSpan.FromSeconds(30)), Nonce, CancellationToken.None))
            .Status.ShouldBe(AppleValidationStatus.Valid);
    }

    [Fact]
    public async Task A_missing_nonce_claim_is_refused()
    {
        await ShouldRefuseAsync(Mint(o => o.RawNonce = null), AuthFailure.TokenNonceMissing);
    }

    [Theory]
    [InlineData("other-raw-nonce")]
    [InlineData("")]
    public async Task A_nonce_that_does_not_hash_to_the_claim_is_refused(string sentNonce)
    {
        var result = await Validator().ValidateAsync(Mint(), sentNonce, CancellationToken.None);

        result.Status.ShouldBe(AppleValidationStatus.Invalid);
        result.Failure.ShouldBe(AuthFailure.TokenNonceMismatch);
    }

    [Fact]
    public async Task The_claim_must_be_the_hash_not_the_raw_nonce_and_lowercase_hex()
    {
        await ShouldRefuseAsync(Mint(o => o.NonceClaim = Nonce), AuthFailure.TokenNonceMismatch);
        await ShouldRefuseAsync(Mint(o => o.NonceClaim = AppleNonce.ExpectedClaim(Nonce).ToUpperInvariant()), AuthFailure.TokenNonceMismatch);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public async Task An_empty_subject_is_refused(string? subject)
    {
        await ShouldRefuseAsync(Mint(o => o.Subject = subject), AuthFailure.TokenSubjectInvalid);
    }

    [Fact]
    public async Task An_overlong_subject_is_refused()
    {
        await ShouldRefuseAsync(Mint(o => o.Subject = new string('s', AppleIdentityOptions.MaxSubjectLength + 1)), AuthFailure.TokenSubjectInvalid);
        (await Validator().ValidateAsync(Mint(o => o.Subject = new string('s', AppleIdentityOptions.MaxSubjectLength)), Nonce, CancellationToken.None))
            .Status.ShouldBe(AppleValidationStatus.Valid);
    }

    [Fact]
    public async Task An_unknown_key_id_forces_one_refresh_and_is_then_refused()
    {
        var result = await Validator().ValidateAsync(Mint(o => o.KeyId = "NOT-PUBLISHED"), Nonce, CancellationToken.None);

        result.Status.ShouldBe(AppleValidationStatus.Invalid);
        result.Failure.ShouldBe(AuthFailure.TokenUnknownKey);
        _keys.ForcedRefreshes.ShouldBe(1);
    }

    [Fact]
    public async Task A_key_rotated_at_Apple_is_picked_up_by_the_forced_refresh()
    {
        _keys.RotateOnRefresh(_key, _otherKey);

        var result = await Validator().ValidateAsync(Mint(o => o.Key = _otherKey), Nonce, CancellationToken.None);

        result.Status.ShouldBe(AppleValidationStatus.Valid);
        _keys.ForcedRefreshes.ShouldBe(1);
    }

    [Fact]
    public async Task HMAC_signed_tokens_naming_a_published_key_id_are_refused_as_the_wrong_algorithm()
    {
        await ShouldRefuseAsync(AppleTestTokens.MintHmac("KID-A", Start, Nonce), AuthFailure.TokenAlgorithm);
    }

    [Fact]
    public async Task Unsigned_tokens_are_refused()
    {
        await ShouldRefuseAsync(AppleTestTokens.MintUnsigned("KID-A", Start, Nonce), AuthFailure.TokenAlgorithm);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-a-jwt")]
    [InlineData("a.b")]
    [InlineData("a.b.c")]
    [InlineData("eyJhbGciOiJSUzI1NiJ9.e30.c2ln")]
    public async Task Garbage_is_refused_without_asking_for_Apples_keys(string token)
    {
        var result = await Validator().ValidateAsync(token, Nonce, CancellationToken.None);

        result.Status.ShouldBe(AppleValidationStatus.Invalid);
        _keys.Calls.ShouldBe(0);
    }

    [Fact]
    public async Task Unreachable_keys_are_unavailable_not_a_bad_token()
    {
        _keys.Unavailable = true;

        var result = await Validator().ValidateAsync(Mint(), Nonce, CancellationToken.None);

        result.Status.ShouldBe(AppleValidationStatus.Unavailable);
        result.Failure.ShouldBeNull();
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("  ")]
    public async Task Without_a_client_id_sign_in_is_unavailable_and_keys_are_not_fetched(string? clientId)
    {
        var result = await Validator(clientId).ValidateAsync(Mint(), Nonce, CancellationToken.None);

        result.Status.ShouldBe(AppleValidationStatus.Unavailable);
        _keys.Calls.ShouldBe(0);
    }

    private async Task ShouldRefuseAsync(string token, AuthFailure expected)
    {
        var result = await Validator().ValidateAsync(token, Nonce, CancellationToken.None);

        result.Status.ShouldBe(AppleValidationStatus.Invalid);
        result.Identity.ShouldBeNull();
        result.Failure.ShouldBe(expected);
    }

    private sealed class MintOptions
    {
        public AppleTestKey? Key { get; set; }
        public string? RawNonce { get; set; } = Nonce;
        public string? Subject { get; set; } = AppleTestTokens.Subject;
        public string Issuer { get; set; } = AppleIdentityOptions.Issuer;
        public string Audience { get; set; } = AppleTestTokens.ClientId;
        public TimeSpan? Lifetime { get; set; }
        public TimeSpan? NotBeforeOffset { get; set; }
        public string? NonceClaim { get; set; }
        public bool IncludeExpiry { get; set; } = true;
        public string? KeyId { get; set; }
    }
}
