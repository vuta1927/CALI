using Cali.Api.Errors;
using Microsoft.Net.Http.Headers;

namespace Cali.Api.Endpoints;

/// <summary>Shared JSON body handling for write endpoints (plan create, sync push).</summary>
internal static class RequestBody
{
    /// <summary>Request body cap for writes; a full 7-day plan or 100 sync mutations are far below this.</summary>
    internal const int MaxBodyBytes = 1024 * 1024;

    internal static bool IsJson(string? contentType) =>
        MediaTypeHeaderValue.TryParse(contentType, out var media)
        && (media.MediaType.Equals("application/json", StringComparison.OrdinalIgnoreCase)
            || (media.MediaType.StartsWith("application/", StringComparison.OrdinalIgnoreCase)
                && media.MediaType.EndsWith("+json", StringComparison.OrdinalIgnoreCase)))
        && (media.Charset.Length == 0 || media.Charset.Equals("utf-8", StringComparison.OrdinalIgnoreCase));

    /// <summary>Reads at most <see cref="MaxBodyBytes"/>; null when the body is larger (chunked uploads have no Content-Length).</summary>
    internal static async Task<byte[]?> ReadAsync(Stream body, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(body);
        using var buffer = new MemoryStream();
        var chunk = new byte[16 * 1024];
        int read;
        while ((read = await body.ReadAsync(chunk, cancellationToken).ConfigureAwait(false)) > 0)
        {
            if (buffer.Length + read > MaxBodyBytes)
            {
                return null;
            }

            buffer.Write(chunk, 0, read);
        }

        return buffer.ToArray();
    }

    internal static IResult ValidationFailed(IReadOnlyDictionary<string, string[]> errors) =>
        Results.Problem(
            statusCode: StatusCodes.Status400BadRequest,
            title: "Request validation failed.",
            extensions: new Dictionary<string, object?>
            {
                [ProblemDetailsEnricher.CodeKey] = ProblemCodes.ValidationFailed,
                ["errors"] = errors,
            });

    internal static IResult UnsupportedMediaType() =>
        Problem(StatusCodes.Status415UnsupportedMediaType, "Content-Type must be application/json.", ProblemCodes.UnsupportedMediaType);

    internal static IResult TooLarge() =>
        Problem(StatusCodes.Status413PayloadTooLarge, "Request body must be at most 1 MiB.", ProblemCodes.PayloadTooLarge);

    internal static IResult Problem(int status, string title, string code) =>
        Results.Problem(statusCode: status, title: title, extensions: new Dictionary<string, object?> { [ProblemDetailsEnricher.CodeKey] = code });

    internal static IResult BadRequest(string title) =>
        Results.Problem(statusCode: StatusCodes.Status400BadRequest, title: title);
}
