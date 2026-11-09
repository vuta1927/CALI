using System.Text.Json;
using Cali.Api.Errors;
using Cali.Api.RateLimiting;
using Cali.Application.Abstractions;
using Cali.Application.Plans;
using Cali.Domain.Plans;
using static Cali.Api.Endpoints.RequestBody;

namespace Cali.Api.Endpoints;

/// <summary>OpenAPI <c>PlanPage</c>; items are serialized <c>TrainingPlan</c> records.</summary>
public sealed record PlanPageResponse(IReadOnlyList<TrainingPlan> Items, string? NextCursor, bool HasMore);

public static class PlanEndpoints
{
    internal const string IdempotencyKeyHeader = "Idempotency-Key";

    private static readonly JsonSerializerOptions RequestJson = new(JsonSerializerDefaults.Web);

    public static IEndpointRouteBuilder MapPlanEndpoints(this IEndpointRouteBuilder app)
    {
        // User data: authenticated, scoped to the token subject, rate limited per user.
        // The group is "/v1" (not "/v1/plans" + "") so the route pattern is exactly "/v1/plans", no trailing slash.
        var plans = app.MapGroup("/v1").RequireAuthorization().RequireRateLimiting(RateLimitPolicies.Sync);

        plans.MapGet("/plans", ListPlansAsync).WithName("listPlans");
        plans.MapPost("/plans", CreatePlanAsync).WithName("createPlan");
        return app;
    }

    private static async Task<IResult> ListPlansAsync(
        HttpRequest request, ICurrentUser currentUser, ListPlans query, CancellationToken cancellationToken)
    {
        if (!QueryParameters.TryLimit(request.Query, ListPlans.DefaultLimit, ListPlans.MaxLimit, out var limit))
        {
            return BadRequest("Parameter 'limit' must be an integer between 1 and 100.");
        }

        PlanCursor? after = null;
        if (!QueryParameters.TrySingle(request.Query, "cursor", out var cursor) || (cursor is not null && !PlanCursor.TryDecode(cursor, out after)))
        {
            return BadRequest("Parameter 'cursor' is not a cursor returned by this endpoint.");
        }

        var page = await query.ExecuteAsync(currentUser.UserId, after, limit, cancellationToken).ConfigureAwait(false);
        return Results.Ok(new PlanPageResponse(page.Items, page.NextCursor?.Encode(), page.HasMore));
    }

    private static async Task<IResult> CreatePlanAsync(
        HttpRequest request, ICurrentUser currentUser, CreatePlan command, CancellationToken cancellationToken)
    {
        var keys = request.Headers[IdempotencyKeyHeader];
        if (keys.Count != 1 || !Guid.TryParse(keys[0], out var idempotencyKey))
        {
            return BadRequest("Header 'Idempotency-Key' must be a single UUID.");
        }

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
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return ValidationFailed(new Dictionary<string, string[]> { [""] = ["Must be an object."] });
            }

            var requestSha256 = PlanRequestHash.Compute(document.RootElement);
            CreatePlanInput? input;
            try
            {
                input = document.RootElement.Deserialize<CreatePlanInput>(RequestJson);
            }
            catch (JsonException e)
            {
                // A value of the wrong JSON type (e.g. a string where an integer is expected).
                var field = e.Path is { Length: > 1 } path && path.StartsWith("$.", StringComparison.Ordinal) ? path[2..] : "";
                return ValidationFailed(new Dictionary<string, string[]> { [field] = ["Invalid value."] });
            }

            if (input is null)
            {
                return ValidationFailed(new Dictionary<string, string[]> { [""] = ["Must be an object."] });
            }

            var result = await command
                .ExecuteAsync(currentUser.UserId, idempotencyKey, requestSha256, input, cancellationToken)
                .ConfigureAwait(false);
            return result.Status switch
            {
                CreatePlanStatus.Created or CreatePlanStatus.Replayed =>
                    Results.Content(result.ResponseBody, "application/json", statusCode: StatusCodes.Status201Created),
                CreatePlanStatus.ValidationFailed => ValidationFailed(result.Errors!.ToDictionary()),
                CreatePlanStatus.IdempotencyKeyReused => Problem(
                    StatusCodes.Status409Conflict, "Idempotency-Key was already used with a different request.", ProblemCodes.IdempotencyKeyReused),
                CreatePlanStatus.UserNotFound => Problem(StatusCodes.Status404NotFound, "User not found.", ProblemCodes.UserNotFound),
                CreatePlanStatus.PlanCountLimit => Problem(
                    StatusCodes.Status409Conflict, "The number of active plans is at its limit.", ProblemCodes.PlanCountLimit),
                _ => Problem(StatusCodes.Status409Conflict, "A plan, workout or exercise with one of these ids already exists.", ProblemCodes.Conflict),
            };
        }
    }
}
