using System.Globalization;
using System.Text.Json;
using Cali.Api.Errors;
using Cali.Api.RateLimiting;
using Cali.Application.Catalog;
using Cali.Domain.Catalog;
using Microsoft.Net.Http.Headers;

namespace Cali.Api.Endpoints;

/// <summary>OpenAPI <c>ExerciseMedia</c>.</summary>
public sealed record ExerciseMediaResponse(
    Guid Id, string Kind, int ContentVersion, Uri? Url, DateTimeOffset? UrlExpiresAt, string MimeType, string Sha256,
    long? SizeBytes, long? DurationMs, string License, string? Attribution)
{
    /// <summary>
    /// <paramref name="signer"/> null, or a key it will not sign, gives <c>url: null</c> and <c>urlExpiresAt: null</c>
    /// (ADR-072); <see cref="CatalogMedia.StorageKey"/> itself is never sent.
    /// </summary>
    public static ExerciseMediaResponse From(CatalogMedia media, IMediaUrlSigner? signer = null, DateTimeOffset issuedAt = default)
    {
        var signed = signer?.Sign(media.StorageKey, issuedAt);
        return new(
            media.Id, media.Kind, media.ContentVersion, signed?.Url, signed?.ExpiresAt, media.MimeType, media.Sha256,
            media.SizeBytes, media.DurationMs, media.License, media.Attribution);
    }
}

/// <summary>OpenAPI <c>Exercise</c>.</summary>
public sealed record ExerciseResponse(
    Guid Id, string Slug, string Name, string Type, string Discipline, string MeasurementType,
    IReadOnlyList<string> FocusTags, IReadOnlyList<string> Equipment, IReadOnlyList<string> Cues,
    int CatalogVersion, IReadOnlyList<ExerciseMediaResponse> Media)
{
    public static ExerciseResponse From(CatalogExercise e, IMediaUrlSigner? signer = null, DateTimeOffset issuedAt = default) => new(
        e.Id, e.Slug, e.Name, e.Type, e.Discipline, e.MeasurementType, e.FocusTags, e.Equipment, e.Cues,
        e.CatalogVersion, e.Media.Select(m => ExerciseMediaResponse.From(m, signer, issuedAt)).ToArray());
}

/// <summary>OpenAPI <c>ExercisePage</c>.</summary>
public sealed record ExercisePageResponse(IReadOnlyList<ExerciseResponse> Items, string? NextCursor, bool HasMore);

/// <summary>OpenAPI <c>IndicatorDefinitionSet</c>.</summary>
public sealed record IndicatorDefinitionSetResponse(int Version, DateTimeOffset PublishedAt, IReadOnlyList<IndicatorDefinition> Indicators);

/// <summary>OpenAPI <c>CriteriaConfig</c> (additionalProperties: false).</summary>
public sealed record CriteriaConfigResponse(
    int Version, DateTimeOffset PublishedAt, JsonElement SupportedTypes, JsonElement Criteria, IndicatorDefinitionSetResponse Indicators)
{
    public static CriteriaConfigResponse From(CriteriaConfigSnapshot snapshot)
    {
        // The stored document is {supportedTypes, criteria} (db/008); copy only those two members.
        using var document = JsonDocument.Parse(snapshot.Criteria.DocumentJson);
        var root = document.RootElement;
        var set = snapshot.Indicators;
        return new CriteriaConfigResponse(
            snapshot.Criteria.Version,
            snapshot.Criteria.PublishedAt,
            root.GetProperty("supportedTypes").Clone(),
            root.GetProperty("criteria").Clone(),
            new IndicatorDefinitionSetResponse(set.Version, set.PublishedAt, set.Indicators));
    }
}

public static class CatalogEndpoints
{
    internal const string PublicCacheControl = "public, max-age=300";

    // The exercise bodies carry signed media URLs that stop working after Media:UrlLifetimeSeconds (ADR-072).
    // A cached copy, shared or private, would serve dead links, so these responses are never stored.
    internal const string UncacheableMediaUrls = "no-store";
    private const int MaxQueryLength = 100;
    private const int MaxEquipmentLength = 50;
    private const int MaxIfNoneMatchLength = 200;

    public static IEndpointRouteBuilder MapCatalogEndpoints(this IEndpointRouteBuilder app)
    {
        // Publisher content without user data: anonymous (OpenAPI `security: []`), rate limited per IP.
        var catalog = app.MapGroup("/v1").AllowAnonymous().RequireRateLimiting(RateLimitPolicies.Public);

        catalog.MapGet("/exercises", ListExercisesAsync).WithName("listExercises");
        catalog.MapGet("/exercises/{id:guid}", GetExerciseAsync).WithName("getExercise");
        catalog.MapGet("/criteria-config", GetCriteriaConfigAsync).WithName("getCriteriaConfig");
        return app;
    }

    private static async Task<IResult> ListExercisesAsync(
        HttpRequest request, HttpResponse response, ListExercises query, IMediaUrlSigner signer, TimeProvider time, CancellationToken cancellationToken)
    {
        response.Headers.CacheControl = UncacheableMediaUrls;

        if (!QueryParameters.TrySingle(request.Query, "q", out var q) || q is { Length: > MaxQueryLength })
        {
            return BadRequest("Parameter 'q' must be at most 100 characters.");
        }

        if (!QueryParameters.TrySingle(request.Query, "type", out var type) || (type is not null && !ExerciseTypes.IsKnown(type)))
        {
            return BadRequest("Parameter 'type' must be an ExerciseType value.");
        }

        if (!QueryParameters.TrySingle(request.Query, "equipment", out var equipment) || equipment is { Length: > MaxEquipmentLength })
        {
            return BadRequest("Parameter 'equipment' must be at most 50 characters.");
        }

        if (!QueryParameters.TryLimit(request.Query, ListExercises.DefaultLimit, ListExercises.MaxLimit, out var limit))
        {
            return BadRequest("Parameter 'limit' must be an integer between 1 and 100.");
        }

        ExerciseCursor? after = null;
        if (!QueryParameters.TrySingle(request.Query, "cursor", out var cursor) || (cursor is not null && !ExerciseCursor.TryDecode(cursor, out after)))
        {
            return BadRequest("Parameter 'cursor' is not a cursor returned by this endpoint.");
        }

        var filter = new ExerciseFilter(NullIfEmpty(q), type, NullIfEmpty(equipment));
        var page = await query.ExecuteAsync(filter, after, limit, cancellationToken).ConfigureAwait(false);
        // One issue time for the whole page, so every URL of a response expires together.
        var issuedAt = time.GetUtcNow();
        return Results.Ok(new ExercisePageResponse(
            page.Items.Select(e => ExerciseResponse.From(e, signer, issuedAt)).ToArray(), page.NextCursor?.Encode(), page.HasMore));
    }

    private static async Task<IResult> GetExerciseAsync(
        Guid id, HttpResponse response, GetExercise query, IMediaUrlSigner signer, TimeProvider time, CancellationToken cancellationToken)
    {
        response.Headers.CacheControl = UncacheableMediaUrls;

        var exercise = await query.ExecuteAsync(id, cancellationToken).ConfigureAwait(false);
        return exercise is null
            ? Results.Problem(statusCode: StatusCodes.Status404NotFound, title: "Exercise not found.")
            : Results.Ok(ExerciseResponse.From(exercise, signer, time.GetUtcNow()));
    }

    private static async Task<IResult> GetCriteriaConfigAsync(HttpContext http, GetCriteriaConfig query, CancellationToken cancellationToken)
    {
        int? version = null;
        if (!QueryParameters.TrySingle(http.Request.Query, "version", out var rawVersion))
        {
            return BadRequest("Parameter 'version' must be a positive integer.");
        }

        if (rawVersion is not null)
        {
            if (!int.TryParse(rawVersion, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed) || parsed < 1)
            {
                return BadRequest("Parameter 'version' must be a positive integer.");
            }

            version = parsed;
        }

        // RFC 9110 §5.3: repeated header lines form one comma-separated list; the limit applies to the whole list.
        var ifNoneMatch = http.Request.Headers.IfNoneMatch.ToString();
        if (ifNoneMatch.Length > MaxIfNoneMatchLength)
        {
            return BadRequest("Header 'If-None-Match' must be at most 200 characters.");
        }

        var snapshot = await query.ExecuteAsync(version, cancellationToken).ConfigureAwait(false);
        if (snapshot is null)
        {
            return Results.Problem(
                statusCode: StatusCodes.Status404NotFound,
                title: "Criteria config version is not published.",
                extensions: new Dictionary<string, object?> { [ProblemDetailsEnricher.CodeKey] = ProblemCodes.CriteriaVersionNotFound });
        }

        var headers = http.Response.Headers;
        headers.ETag = snapshot.ETag;
        headers.CacheControl = PublicCacheControl;

        return Matches(ifNoneMatch, snapshot.ETag)
            ? Results.StatusCode(StatusCodes.Status304NotModified)
            : Results.Ok(CriteriaConfigResponse.From(snapshot));
    }

    /// <summary>
    /// RFC 9110 §13.1.2: <c>If-None-Match</c> uses weak comparison, accepts a list and <c>*</c>.
    /// Malformed entries never match (the full response is returned).
    /// </summary>
    internal static bool Matches(string? ifNoneMatch, string etag)
    {
        if (string.IsNullOrWhiteSpace(ifNoneMatch))
        {
            return false;
        }

        if (ifNoneMatch.Trim() == "*")
        {
            return true;
        }

        if (!EntityTagHeaderValue.TryParseList([ifNoneMatch], out var tags))
        {
            return false;
        }

        var current = new EntityTagHeaderValue(etag);
        return tags.Any(t => t.Compare(current, useStrongComparison: false));
    }

    private static string? NullIfEmpty(string? value) => string.IsNullOrEmpty(value) ? null : value;

    private static IResult BadRequest(string title) =>
        Results.Problem(statusCode: StatusCodes.Status400BadRequest, title: title);
}
