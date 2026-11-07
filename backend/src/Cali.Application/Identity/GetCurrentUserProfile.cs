using Cali.Application.Abstractions;
using Cali.Domain.Identity;

namespace Cali.Application.Identity;

/// <summary>Use case behind <c>GET /v1/me</c>: load the profile of the authenticated caller.</summary>
public sealed class GetCurrentUserProfile(ICurrentUser currentUser, IUserProfileReader reader)
{
    /// <returns>The caller's profile, or null when no (non-deleted) user row exists for the token subject.</returns>
    public Task<UserProfile?> ExecuteAsync(CancellationToken cancellationToken) =>
        reader.FindByIdAsync(currentUser.UserId, cancellationToken);
}
