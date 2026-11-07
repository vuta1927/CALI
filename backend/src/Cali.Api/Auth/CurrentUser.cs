using System.Security.Claims;
using Cali.Application.Abstractions;

namespace Cali.Api.Auth;

/// <summary>Reads the caller's internal user id from the validated token's <c>sub</c> claim only.</summary>
public static class CurrentUserClaims
{
    public const string Subject = "sub";

    /// <summary>
    /// True only for an authenticated principal carrying exactly one <c>sub</c> claim that is a non-empty UUID.
    /// Other id-like claims (nameidentifier, uid, user_id, …) are deliberately ignored.
    /// </summary>
    public static bool TryGetUserId(ClaimsPrincipal? principal, out Guid userId)
    {
        userId = Guid.Empty;
        if (principal?.Identity?.IsAuthenticated != true)
        {
            return false;
        }

        var subjects = principal.FindAll(Subject).Take(2).ToArray();
        if (subjects.Length != 1)
        {
            return false;
        }

        if (!Guid.TryParseExact(subjects[0].Value, "D", out var parsed) || parsed == Guid.Empty)
        {
            return false;
        }

        userId = parsed;
        return true;
    }
}

internal sealed class HttpCurrentUser(IHttpContextAccessor accessor) : ICurrentUser
{
    public bool IsAuthenticated => CurrentUserClaims.TryGetUserId(accessor.HttpContext?.User, out _);

    public Guid UserId => CurrentUserClaims.TryGetUserId(accessor.HttpContext?.User, out var id)
        ? id
        : throw new InvalidOperationException("No authenticated user with a valid 'sub' claim on this request.");
}
