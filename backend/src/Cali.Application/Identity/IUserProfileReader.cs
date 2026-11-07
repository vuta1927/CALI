using Cali.Domain.Identity;

namespace Cali.Application.Identity;

public interface IUserProfileReader
{
    /// <summary>Returns the non-deleted user with the given internal id, or null.</summary>
    Task<UserProfile?> FindByIdAsync(Guid userId, CancellationToken cancellationToken);
}
