using System.Diagnostics;
using Microsoft.AspNetCore.Mvc;

namespace Cali.Api.Errors;

/// <summary>Stable machine-readable error codes (OpenAPI <c>Problem.code</c>).</summary>
public static class ProblemCodes
{
    public const string BadRequest = "bad_request";
    public const string Unauthorized = "unauthorized";
    public const string InvalidToken = "invalid_token";
    public const string Forbidden = "forbidden";
    public const string NotFound = "not_found";
    public const string MethodNotAllowed = "method_not_allowed";
    public const string Conflict = "conflict";
    public const string PayloadTooLarge = "payload_too_large";
    public const string UnsupportedMediaType = "unsupported_media_type";
    public const string ValidationFailed = "validation_failed";
    public const string RateLimited = "rate_limited";
    public const string InternalError = "internal_error";
    public const string ServiceUnavailable = "service_unavailable";
    public const string UserNotFound = "user_not_found";

    public const string DeviceOwnerMismatch = "device_owner_mismatch";
    public const string CursorExpired = "cursor_expired";
    public const string CriteriaVersionNotFound = "criteria_version_not_found";
    public const string PlanCountLimit = "plan_count_limit";
    public const string IdempotencyKeyReused = "idempotency_key_reused";

    public static string ForStatus(int status) => status switch
    {
        400 => BadRequest,
        401 => Unauthorized,
        403 => Forbidden,
        404 => NotFound,
        405 => MethodNotAllowed,
        409 => Conflict,
        413 => PayloadTooLarge,
        415 => UnsupportedMediaType,
        422 => ValidationFailed,
        429 => RateLimited,
        500 => InternalError,
        503 => ServiceUnavailable,
        _ => $"http_{status}",
    };
}

/// <summary>
/// Shapes every problem+json response to the OpenAPI <c>Problem</c> schema:
/// required <c>type</c>, <c>title</c>, <c>status</c>, <c>code</c>, <c>traceId</c>. No exception details or secrets.
/// </summary>
public static class ProblemDetailsEnricher
{
    public const string CodeKey = "code";
    public const string TraceIdKey = "traceId";

    public static void Enrich(ProblemDetails problem, HttpContext http)
    {
        ArgumentNullException.ThrowIfNull(problem);
        ArgumentNullException.ThrowIfNull(http);

        var status = problem.Status ?? (http.Response.StatusCode >= 400 ? http.Response.StatusCode : StatusCodes.Status500InternalServerError);
        problem.Status = status;
        problem.Type ??= "about:blank";
        problem.Title ??= ReasonPhrase(status);

        if (problem.Extensions.TryGetValue(CodeKey, out var code) is false || code is not string { Length: > 0 })
        {
            problem.Extensions[CodeKey] = ProblemCodes.ForStatus(status);
        }

        problem.Extensions[TraceIdKey] = Activity.Current?.TraceId.ToHexString() ?? http.TraceIdentifier;

        // Never surface server internals (the framework may attach these in some paths).
        problem.Extensions.Remove("exception");
        if (status >= 500)
        {
            problem.Detail = null;
        }
    }

    private static string ReasonPhrase(int status) =>
        Microsoft.AspNetCore.WebUtilities.ReasonPhrases.GetReasonPhrase(status) is { Length: > 0 } phrase ? phrase : "Error";
}
