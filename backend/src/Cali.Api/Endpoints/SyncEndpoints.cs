using System.Text.Json;
using System.Text.Json.Nodes;
using Cali.Api.Errors;
using Cali.Api.RateLimiting;
using Cali.Application.Abstractions;
using Cali.Application.Sync;
using static Cali.Api.Endpoints.RequestBody;

namespace Cali.Api.Endpoints;

public static class SyncEndpoints
{
    public static IEndpointRouteBuilder MapSyncEndpoints(this IEndpointRouteBuilder app)
    {
        var sync = app.MapGroup("/v1").RequireAuthorization().RequireRateLimiting(RateLimitPolicies.Sync);
        sync.MapPost("/sync/push", PushAsync).WithName("syncPush");
        return app;
    }

    // The body is never logged: it may carry body measurements (ADR-064) and free-text notes.
    private static async Task<IResult> PushAsync(
        HttpRequest request, ICurrentUser currentUser, SyncPush command, CancellationToken cancellationToken)
    {
        if (!IsJson(request.ContentType))
        {
            return UnsupportedMediaType();
        }

        if (request.ContentLength > MaxBodyBytes)
        {
            return TooLarge();
        }

        var body = await ReadAsync(request.Body, cancellationToken).ConfigureAwait(false);
        if (body is null)
        {
            return TooLarge();
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(body);
        }
        catch (JsonException)
        {
            return BadRequest("Request body is not valid JSON.");
        }

        using (document)
        {
            var result = await command.ExecuteAsync(currentUser.UserId, document.RootElement, cancellationToken).ConfigureAwait(false);
            return result.Status switch
            {
                SyncPushStatus.Pushed => Results.Content(
                    new JsonObject { ["results"] = new JsonArray([.. result.Receipts!.Select(r => (JsonNode)r.ToJson())]) }.ToJsonString(),
                    "application/json"),
                SyncPushStatus.ValidationFailed => ValidationFailed(result.Errors!.ToDictionary()),
                SyncPushStatus.UserNotFound => Problem(StatusCodes.Status404NotFound, "User not found.", ProblemCodes.UserNotFound),
                _ => Problem(StatusCodes.Status409Conflict, "This deviceId is registered to another user.", ProblemCodes.DeviceOwnerMismatch),
            };
        }
    }
}
