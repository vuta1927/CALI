using System.Text.Json;
using Cali.Api.Errors;
using Cali.Api.RateLimiting;
using Cali.Application.Identity;
using static Cali.Api.Endpoints.RequestBody;

namespace Cali.Api.Endpoints;

/// <summary>OpenAPI <c>AuthTokens</c>.</summary>
public sealed record AuthTokensResponse(string AccessToken, string RefreshToken, int ExpiresInSeconds, UserProfileResponse User)
{
    public static AuthTokensResponse From(AuthSession session) =>
        new(session.AccessToken, session.RefreshToken, session.ExpiresInSeconds, UserProfileResponse.From(session.User));
}

/// <summary>
/// Sign in with Apple and refresh token rotation (BE-005, ADR-071). Both endpoints are anonymous and rate limited per
/// client IP. Every refusal is the same 401 with no reason: the reason is logged as a code, never a token.
/// </summary>
public static class AuthEndpoints
{
    // Bodies hold one token (an Apple identity token is about 1.2 KiB), so a small cap is plenty.
    internal const int MaxBodyBytes = 16 * 1024;
    internal const int MaxIdentityTokenLength = 8192;
    internal const int MinNonceLength = 8;
    internal const int MaxNonceLength = 256;
    internal const int MinTokenLength = 10;
    internal const int MaxRefreshTokenLength = 128;
    private const int RetryAfterSeconds = 30;

    public static IEndpointRouteBuilder MapAuthEndpoints(this IEndpointRouteBuilder app)
    {
        var auth = app.MapGroup("/v1/auth").AllowAnonymous().RequireRateLimiting(RateLimitPolicies.Auth);
        auth.MapPost("/apple", AppleAsync).WithName("authenticateWithApple");
        auth.MapPost("/refresh", RefreshAsync).WithName("refreshAuthToken");
        return app;
    }

    private static async Task<IResult> AppleAsync(
        HttpRequest request, HttpResponse response, AuthenticateWithApple command, ILoggerFactory loggers, CancellationToken cancellationToken)
    {
        response.Headers.CacheControl = "no-store";
        var (root, failure) = await ReadObjectAsync(request, cancellationToken).ConfigureAwait(false);
        if (failure is not null)
        {
            return failure;
        }

        using (root)
        {
            var errors = new Dictionary<string, string[]>();
            var identityToken = ReadString(root!.RootElement, "identityToken", MinTokenLength, MaxIdentityTokenLength, required: true, errors);
            var nonce = ReadString(root.RootElement, "nonce", MinNonceLength, MaxNonceLength, required: true, errors);
            var deviceId = ReadDeviceId(root.RootElement, errors);
            if (errors.Count > 0)
            {
                return ValidationFailed(errors);
            }

            var result = await command.ExecuteAsync(identityToken!, nonce!, deviceId, cancellationToken).ConfigureAwait(false);
            return Respond(result, response, loggers, "Apple sign-in");
        }
    }

    private static async Task<IResult> RefreshAsync(
        HttpRequest request, HttpResponse response, RefreshSession command, ILoggerFactory loggers, CancellationToken cancellationToken)
    {
        response.Headers.CacheControl = "no-store";
        var (root, failure) = await ReadObjectAsync(request, cancellationToken).ConfigureAwait(false);
        if (failure is not null)
        {
            return failure;
        }

        using (root)
        {
            var errors = new Dictionary<string, string[]>();
            var refreshToken = ReadString(root!.RootElement, "refreshToken", MinTokenLength, MaxRefreshTokenLength, required: true, errors);
            var deviceId = ReadDeviceId(root.RootElement, errors);
            if (errors.Count > 0)
            {
                return ValidationFailed(errors);
            }

            var result = await command.ExecuteAsync(refreshToken!, deviceId, cancellationToken).ConfigureAwait(false);
            return Respond(result, response, loggers, "Token refresh");
        }
    }

    private static IResult Respond(AuthResult result, HttpResponse response, ILoggerFactory loggers, string operation)
    {
        var logger = loggers.CreateLogger("Cali.Api.Auth");
        switch (result.Status)
        {
            case AuthStatus.Authenticated:
                return Results.Ok(AuthTokensResponse.From(result.Session!));
            case AuthStatus.Unavailable:
                logger.LogWarning("{Operation} unavailable: upstream keys or configuration missing", operation);
                response.Headers.RetryAfter = RetryAfterSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
                return Problem(StatusCodes.Status503ServiceUnavailable, "Authentication is temporarily unavailable.", ProblemCodes.ServiceUnavailable);
            default:
                // A reused refresh token means a stolen or replayed credential: worth a warning. Only the reason code is logged.
                var level = result.Failure == AuthFailure.RefreshReused ? LogLevel.Warning : LogLevel.Information;
                logger.Log(level, "{Operation} refused: {Reason}", operation, result.Failure);
                return Problem(StatusCodes.Status401Unauthorized, "Authentication failed.", ProblemCodes.Unauthorized);
        }
    }

    private static async Task<(JsonDocument? Root, IResult? Failure)> ReadObjectAsync(HttpRequest request, CancellationToken cancellationToken)
    {
        if (!IsJson(request.ContentType))
        {
            return (null, UnsupportedMediaType());
        }

        var tooLarge = Problem(StatusCodes.Status413PayloadTooLarge, "Request body must be at most 16 KiB.", ProblemCodes.PayloadTooLarge);
        if (request.ContentLength > MaxBodyBytes)
        {
            return (null, tooLarge);
        }

        var body = await ReadAsync(request.Body, cancellationToken, MaxBodyBytes).ConfigureAwait(false);
        if (body is null)
        {
            return (null, tooLarge);
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(body);
        }
        catch (JsonException)
        {
            return (null, BadRequest("Request body is not valid JSON."));
        }

        if (document.RootElement.ValueKind != JsonValueKind.Object)
        {
            document.Dispose();
            return (null, ValidationFailed(new Dictionary<string, string[]> { [""] = ["The request body must be a JSON object."] }));
        }

        return (document, null);
    }

    private static string? ReadString(JsonElement root, string name, int min, int max, bool required, Dictionary<string, string[]> errors)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            if (required)
            {
                errors[name] = ["Required."];
            }

            return null;
        }

        if (value.ValueKind != JsonValueKind.String)
        {
            errors[name] = ["Must be a string."];
            return null;
        }

        var text = value.GetString()!;
        if (text.Length < min || text.Length > max)
        {
            errors[name] = [$"Must be between {min} and {max} characters."];
            return null;
        }

        return text;
    }

    private static Guid? ReadDeviceId(JsonElement root, Dictionary<string, string[]> errors)
    {
        if (!root.TryGetProperty("deviceId", out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (value.ValueKind != JsonValueKind.String || !Guid.TryParseExact(value.GetString(), "D", out var id) || id == Guid.Empty)
        {
            errors["deviceId"] = ["Must be a UUID."];
            return null;
        }

        return id;
    }
}
