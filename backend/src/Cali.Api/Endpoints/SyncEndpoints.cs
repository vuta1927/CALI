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
        sync.MapGet("/sync/pull", PullAsync).WithName("syncPull");
        return app;
    }

    // Payloads are user data (workout logs, body measurements): never cached, never logged.
    private static async Task<IResult> PullAsync(
        HttpRequest request, HttpResponse response, ICurrentUser currentUser, PullChanges query, CancellationToken cancellationToken)
    {
        response.Headers.CacheControl = "no-store";

        if (!QueryParameters.TryLimit(request.Query, PullChanges.DefaultLimit, PullChanges.MaxLimit, out var limit))
        {
            return BadRequest("Parameter 'limit' must be an integer between 1 and 100.");
        }

        if (!QueryParameters.TrySingle(request.Query, "cursor", out var cursor))
        {
            return BadRequest("Parameter 'cursor' must not be repeated.");
        }

        var result = await query.ExecuteAsync(currentUser.UserId, cursor, limit, cancellationToken).ConfigureAwait(false);
        return result.Status switch
        {
            SyncPullStatus.Page => Results.Content(ToJson(result.Page!).ToJsonString(), "application/json"),
            SyncPullStatus.InvalidCursor => BadRequest("Parameter 'cursor' is not a cursor issued to you by this server."),
            _ => Problem(StatusCodes.Status410Gone, "The cursor is too old. Discard local synced data and pull again without a cursor.", ProblemCodes.CursorExpired),
        };
    }

    private static JsonObject ToJson(SyncPullPage page) =>
        new()
        {
            ["changes"] = new JsonArray([.. page.Changes.Select(c => (JsonNode)new JsonObject
            {
                ["changeId"] = c.ChangeId,
                ["entityType"] = c.Record.EntityType,
                ["entityId"] = c.Record.EntityId.ToString("D"),
                ["operation"] = c.Record.Operation,
                ["serverVersion"] = c.Record.ServerVersion,
                ["payload"] = JsonNode.Parse(c.Record.PayloadJson),
            })]),
            ["nextCursor"] = page.NextCursor,
            ["hasMore"] = page.HasMore,
        };

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
