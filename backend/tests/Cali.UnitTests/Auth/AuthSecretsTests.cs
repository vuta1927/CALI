using System.Security.Cryptography;
using System.Text;
using Cali.Application.Identity;
using Cali.Infrastructure.Auth;
using Microsoft.Extensions.Time.Testing;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace Cali.UnitTests.Auth;

/// <summary>B4 (BE-005): refresh token format, nonce convention and the CALI access token.</summary>
public sealed class AuthSecretsTests
{
    [Fact]
    public void A_refresh_token_is_43_url_safe_characters_and_unique()
    {
        var tokens = Enumerable.Range(0, 200).Select(_ => RefreshTokenSecret.Create()).ToList();

        tokens.ShouldAllBe(t => t.Length == RefreshTokenSecret.EncodedLength);
        tokens.ShouldAllBe(t => RefreshTokenSecret.IsWellFormed(t));
        tokens.ShouldAllBe(t => t.All(c => char.IsAsciiLetterOrDigit(c) || c == '-' || c == '_'));
        tokens.Distinct().Count().ShouldBe(tokens.Count);
    }

    [Fact]
    public void The_stored_form_is_the_sha256_of_the_token_text()
    {
        var token = RefreshTokenSecret.Create();

        RefreshTokenSecret.Hash(token).ShouldBe(SHA256.HashData(Encoding.UTF8.GetBytes(token)));
        RefreshTokenSecret.Hash(token).Length.ShouldBe(32);
        RefreshTokenSecret.Hash(token).ShouldNotBe(RefreshTokenSecret.Hash(RefreshTokenSecret.Create()));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("short")]
    [InlineData("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")] // 43 characters, but padding is not part of base64url
    [InlineData("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA+")] // standard alphabet
    [InlineData("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")] // too long
    [InlineData("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ")] // whitespace
    public void Anything_that_is_not_a_token_this_server_issues_is_malformed(string? token)
    {
        RefreshTokenSecret.IsWellFormed(token).ShouldBeFalse();
    }

    [Fact]
    public void Only_the_canonical_encoding_of_32_bytes_is_well_formed()
    {
        // 43 characters carry 258 bits for 256 bits of data: the last character must have its two low bits clear.
        RefreshTokenSecret.IsWellFormed(new string('A', 43)).ShouldBeTrue();
        RefreshTokenSecret.IsWellFormed(new string('A', 42) + "Q").ShouldBeTrue();
        RefreshTokenSecret.IsWellFormed(new string('A', 42) + "B").ShouldBeFalse();
        RefreshTokenSecret.IsWellFormed(new string('A', 42) + "R").ShouldBeFalse();
    }

    [Fact]
    public void The_nonce_claim_is_the_lowercase_hex_sha256_of_the_raw_nonce()
    {
        // FIPS 180-2 test vector for "abc".
        AppleNonce.ExpectedClaim("abc").ShouldBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        AppleNonce.Hash("abc").Length.ShouldBe(32);
        Convert.ToHexStringLower(AppleNonce.Hash("abc")).ShouldBe(AppleNonce.ExpectedClaim("abc"));
    }

    [Fact]
    public async Task An_access_token_validates_with_the_key_issuer_and_audience_and_carries_only_the_user_id()
    {
        var key = RandomNumberGenerator.GetBytes(32);
        var time = new FakeTimeProvider(new DateTimeOffset(2026, 11, 9, 12, 0, 0, TimeSpan.Zero));
        var userId = Guid.NewGuid();
        var issued = new AccessTokenIssuer(key, "cali-api", TimeSpan.FromMinutes(15), time).Issue(userId);

        issued.ExpiresInSeconds.ShouldBe(900);
        var result = await new JsonWebTokenHandler().ValidateTokenAsync(issued.Token, new TokenValidationParameters
        {
            ValidIssuer = AccessTokenDefaults.Issuer,
            ValidAudience = "cali-api",
            IssuerSigningKey = new SymmetricSecurityKey(key),
            ValidAlgorithms = [SecurityAlgorithms.HmacSha256],
            ValidateLifetime = false,
        });

        result.IsValid.ShouldBeTrue(result.Exception?.Message);
        var jwt = (JsonWebToken)result.SecurityToken;
        jwt.Subject.ShouldBe(userId.ToString("D"));
        jwt.ValidTo.ShouldBe(time.GetUtcNow().AddMinutes(15).UtcDateTime);
        jwt.ValidFrom.ShouldBe(time.GetUtcNow().UtcDateTime);
        jwt.Claims.Select(c => c.Type).Order().ShouldBe(["aud", "exp", "iat", "iss", "jti", "nbf", "sub"]);
    }

    [Fact]
    public async Task An_access_token_does_not_validate_under_another_key()
    {
        var issuer = new AccessTokenIssuer(RandomNumberGenerator.GetBytes(32), "cali-api", TimeSpan.FromMinutes(15), TimeProvider.System);

        var result = await new JsonWebTokenHandler().ValidateTokenAsync(issuer.Issue(Guid.NewGuid()).Token, new TokenValidationParameters
        {
            ValidIssuer = AccessTokenDefaults.Issuer,
            ValidAudience = "cali-api",
            IssuerSigningKey = new SymmetricSecurityKey(RandomNumberGenerator.GetBytes(32)),
        });

        result.IsValid.ShouldBeFalse();
    }

    [Fact]
    public void The_issuer_refuses_a_short_key_a_bad_lifetime_and_an_empty_user()
    {
        Should.Throw<ArgumentException>(() => new AccessTokenIssuer(new byte[31], "cali-api", TimeSpan.FromMinutes(1), TimeProvider.System));
        Should.Throw<ArgumentOutOfRangeException>(() => new AccessTokenIssuer(new byte[32], "cali-api", TimeSpan.Zero, TimeProvider.System));
        Should.Throw<ArgumentException>(() => new AccessTokenIssuer(new byte[32], " ", TimeSpan.FromMinutes(1), TimeProvider.System));
        Should.Throw<ArgumentException>(() =>
            new AccessTokenIssuer(RandomNumberGenerator.GetBytes(32), "cali-api", TimeSpan.FromMinutes(1), TimeProvider.System).Issue(Guid.Empty));
    }
}
