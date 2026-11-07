namespace Cali.Application.Abstractions;

/// <summary>
/// The authenticated caller. The user id comes ONLY from the validated access token's
/// <c>sub</c> claim — never from a route, query, header or body value supplied by the client.
/// </summary>
public interface ICurrentUser
{
    /// <summary>True when the request carries a validated token with a well-formed <c>sub</c>.</summary>
    bool IsAuthenticated { get; }

    /// <summary>
    /// Internal user id (<c>users.id</c>) from the token <c>sub</c>.
    /// Throws <see cref="InvalidOperationException"/> when <see cref="IsAuthenticated"/> is false.
    /// </summary>
    Guid UserId { get; }
}
