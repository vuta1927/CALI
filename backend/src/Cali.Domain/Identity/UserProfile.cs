namespace Cali.Domain.Identity;

/// <summary>
/// Internal user identity as stored in <c>users</c>. The id is the internal UUID that the
/// access token's <c>sub</c> claim carries; it is never taken from client-supplied payloads.
/// </summary>
public sealed record UserProfile(Guid Id, string? DisplayName, string Timezone, DateTimeOffset CreatedAt);
