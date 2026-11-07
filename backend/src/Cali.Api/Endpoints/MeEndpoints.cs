using Cali.Api.Errors;
using Cali.Application.Identity;
using Cali.Domain.Identity;

namespace Cali.Api.Endpoints;

/// <summary>OpenAPI <c>UserProfile</c> (required: id, timezone, createdAt; displayName nullable).</summary>
public sealed record UserProfileResponse(Guid Id, string? DisplayName, string Timezone, DateTimeOffset CreatedAt)
{
    public static UserProfileResponse From(UserProfile profile) =>
        new(profile.Id, profile.DisplayName, profile.Timezone, profile.CreatedAt);
}

public static class MeEndpoints
{
    public static IEndpointRouteBuilder MapMeEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/v1/me", async (GetCurrentUserProfile query, CancellationToken cancellationToken) =>
            {
                var profile = await query.ExecuteAsync(cancellationToken).ConfigureAwait(false);
                return profile is null
                    // Valid token whose subject has no (non-deleted) users row. Not yet in the OpenAPI
                    // contract for /v1/me — reported for contract review.
                    ? Results.Problem(
                        statusCode: StatusCodes.Status404NotFound,
                        title: "User not found.",
                        extensions: new Dictionary<string, object?> { [ProblemDetailsEnricher.CodeKey] = ProblemCodes.UserNotFound })
                    : Results.Ok(UserProfileResponse.From(profile));
            })
            .RequireAuthorization()
            .WithName("getMe");

        return app;
    }
}
