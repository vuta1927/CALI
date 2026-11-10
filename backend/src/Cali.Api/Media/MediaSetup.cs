using System.Globalization;
using Cali.Application.Catalog;
using Cali.Infrastructure.Media;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Cali.Api.Media;

/// <summary>Registers the signed media URLs of the catalog (BE-006, ADR-072): object storage settings and the signer.</summary>
public static class MediaSetup
{
    /// <summary>Env: <c>Media__Storage__Endpoint</c>. Origin of the S3-compatible store, for example <c>https://&lt;account&gt;.r2.cloudflarestorage.com</c>.</summary>
    public const string EndpointConfigKey = "Media:Storage:Endpoint";

    /// <summary>Env: <c>Media__Storage__Bucket</c>.</summary>
    public const string BucketConfigKey = "Media:Storage:Bucket";

    /// <summary>Env: <c>Media__Storage__Region</c>. Default <c>auto</c> (Cloudflare R2); AWS S3 needs the bucket's region.</summary>
    public const string RegionConfigKey = "Media:Storage:Region";

    /// <summary>Env: <c>Media__Storage__AccessKeyId</c>. Use a credential that can only read this bucket.</summary>
    public const string AccessKeyIdConfigKey = "Media:Storage:AccessKeyId";

    /// <summary>Env: <c>Media__Storage__SecretAccessKey</c>. Secret; never committed, never logged.</summary>
    public const string SecretAccessKeyConfigKey = "Media:Storage:SecretAccessKey";

    /// <summary>Env: <c>Media__UrlLifetimeSeconds</c>. How long a signed URL works.</summary>
    public const string LifetimeConfigKey = "Media:UrlLifetimeSeconds";

    public const int DefaultLifetimeSeconds = 900;
    public const string DefaultRegion = "auto";

    private static readonly string[] StorageKeys = [EndpointConfigKey, BucketConfigKey, AccessKeyIdConfigKey, SecretAccessKeyConfigKey];

    public static IServiceCollection AddCaliMedia(this IServiceCollection services)
    {
        services.TryAddSingleton(TimeProvider.System);
        services.AddSingleton(sp => ResolveSigner(
            sp.GetRequiredService<IConfiguration>(), sp.GetRequiredService<IHostEnvironment>(),
            sp.GetRequiredService<ILoggerFactory>().CreateLogger(typeof(MediaSetup))));
        return services;
    }

    /// <summary>
    /// Nothing configured: Development runs without object storage (the catalog returns <c>url: null</c>); any other
    /// environment must be configured. A partly configured store is always an error. Messages name keys, never values.
    /// </summary>
    internal static IMediaUrlSigner ResolveSigner(IConfiguration configuration, IHostEnvironment environment, ILogger logger)
    {
        var anySet = StorageKeys.Any(key => !string.IsNullOrWhiteSpace(configuration[key]));
        if (!anySet && environment.IsDevelopment())
        {
            logger.LogInformation("Object storage is not configured ({Key}); catalog media urls stay null.", EndpointConfigKey);
            return new NoMediaUrlSigner();
        }

        var missing = StorageKeys.Where(key => string.IsNullOrWhiteSpace(configuration[key])).ToArray();
        if (missing.Length > 0)
        {
            throw new InvalidOperationException($"Object storage is not fully configured; missing: {string.Join(", ", missing)}.");
        }

        var endpoint = ParseEndpoint(configuration[EndpointConfigKey]!.Trim(), environment);
        var bucket = configuration[BucketConfigKey]!.Trim();
        if (!S3PresignedUrlSigner.IsValidBucket(bucket))
        {
            throw new InvalidOperationException($"{BucketConfigKey} must be a valid bucket name (3..63 characters: a-z, 0-9, '-' and '.').");
        }

        var region = string.IsNullOrWhiteSpace(configuration[RegionConfigKey]) ? DefaultRegion : configuration[RegionConfigKey]!.Trim();
        if (!S3PresignedUrlSigner.IsValidRegion(region))
        {
            throw new InvalidOperationException($"{RegionConfigKey} must be 1..30 characters: a-z, 0-9 and '-'.");
        }

        return new S3PresignedUrlSigner(new S3StorageOptions
        {
            Endpoint = endpoint,
            Bucket = bucket,
            Region = region,
            AccessKeyId = configuration[AccessKeyIdConfigKey]!.Trim(),
            SecretAccessKey = configuration[SecretAccessKeyConfigKey]!.Trim(),
            Lifetime = TimeSpan.FromSeconds(ResolveLifetimeSeconds(configuration)),
        });
    }

    internal static int ResolveLifetimeSeconds(IConfiguration configuration)
    {
        var raw = configuration[LifetimeConfigKey];
        if (string.IsNullOrWhiteSpace(raw))
        {
            return DefaultLifetimeSeconds;
        }

        if (!int.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out var seconds)
            || seconds is < S3PresignedUrlSigner.MinLifetimeSeconds or > S3PresignedUrlSigner.MaxLifetimeSeconds)
        {
            throw new InvalidOperationException(
                $"{LifetimeConfigKey} must be a whole number of seconds between {S3PresignedUrlSigner.MinLifetimeSeconds} and {S3PresignedUrlSigner.MaxLifetimeSeconds}.");
        }

        return seconds;
    }

    private static Uri ParseEndpoint(string value, IHostEnvironment environment)
    {
        // Plain http is only for a local MinIO; a signed URL over http would be readable and replayable on the wire.
        var allowedSchemes = environment.IsDevelopment() ? new[] { "http", "https" } : ["https"];
        if (!Uri.TryCreate(value, UriKind.Absolute, out var endpoint) || !allowedSchemes.Contains(endpoint.Scheme)
            || endpoint.AbsolutePath != "/" || endpoint.Query.Length > 0 || endpoint.Fragment.Length > 0 || endpoint.UserInfo.Length > 0)
        {
            throw new InvalidOperationException(
                $"{EndpointConfigKey} must be an {string.Join(" or ", allowedSchemes)} origin (scheme, host and optional port) without a path, query or credentials.");
        }

        return endpoint;
    }
}
