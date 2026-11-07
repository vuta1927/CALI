using System.Security.Claims;
using Cali.Api.Auth;
using Microsoft.AspNetCore.Http;

namespace Cali.UnitTests.Auth;

public sealed class CurrentUserTests
{
    private static readonly Guid UserId = Guid.Parse("8d1c3f8e-5b7a-4e0c-9a51-0f8a2c1d4b6e");

    private static ClaimsPrincipal Principal(bool authenticated, params Claim[] claims) =>
        new(new ClaimsIdentity(claims, authenticated ? "Bearer" : null));

    [Fact]
    public void Reads_user_id_from_sub_claim()
    {
        CurrentUserClaims.TryGetUserId(Principal(true, new Claim("sub", UserId.ToString())), out var id).ShouldBeTrue();
        id.ShouldBe(UserId);
    }

    [Theory]
    [InlineData(ClaimTypes.NameIdentifier)]
    [InlineData("uid")]
    [InlineData("user_id")]
    [InlineData("oid")]
    public void Ignores_other_id_like_claims(string claimType)
    {
        CurrentUserClaims.TryGetUserId(Principal(true, new Claim(claimType, UserId.ToString())), out var id).ShouldBeFalse();
        id.ShouldBe(Guid.Empty);
    }

    [Fact]
    public void Rejects_unauthenticated_identity_even_with_sub()
    {
        CurrentUserClaims.TryGetUserId(Principal(false, new Claim("sub", UserId.ToString())), out _).ShouldBeFalse();
    }

    [Theory]
    [InlineData("not-a-uuid")]
    [InlineData("00000000-0000-0000-0000-000000000000")]
    [InlineData("8d1c3f8e5b7a4e0c9a510f8a2c1d4b6e")] // must be canonical "D" format
    [InlineData("")]
    public void Rejects_malformed_or_empty_sub(string sub)
    {
        CurrentUserClaims.TryGetUserId(Principal(true, new Claim("sub", sub)), out _).ShouldBeFalse();
    }

    [Fact]
    public void Rejects_multiple_sub_claims()
    {
        var principal = Principal(true, new Claim("sub", UserId.ToString()), new Claim("sub", Guid.NewGuid().ToString()));
        CurrentUserClaims.TryGetUserId(principal, out _).ShouldBeFalse();
    }

    [Fact]
    public void HttpCurrentUser_exposes_sub_and_throws_when_unauthenticated()
    {
        var http = new DefaultHttpContext { User = Principal(true, new Claim("sub", UserId.ToString())) };
        var accessor = new HttpContextAccessor { HttpContext = http };
        var currentUser = new HttpCurrentUser(accessor);

        currentUser.IsAuthenticated.ShouldBeTrue();
        currentUser.UserId.ShouldBe(UserId);

        http.User = new ClaimsPrincipal(new ClaimsIdentity());
        currentUser.IsAuthenticated.ShouldBeFalse();
        Should.Throw<InvalidOperationException>(() => currentUser.UserId);
    }
}
