using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Cali.Application.Catalog;

namespace Cali.Infrastructure.Media;

/// <summary>
/// Connection to an S3-compatible bucket (AWS S3, Cloudflare R2, MinIO). A class, not a record, so the generated
/// <c>ToString</c> can never print the secret.
/// </summary>
public sealed class S3StorageOptions
{
    /// <summary>Scheme, host and optional port; path-style addressing is used, so no path is allowed.</summary>
    public required Uri Endpoint { get; init; }

    public required string Bucket { get; init; }

    /// <summary>Signing region: the AWS region, or <c>auto</c> for Cloudflare R2.</summary>
    public required string Region { get; init; }

    /// <summary>Should belong to a credential that can only read this bucket.</summary>
    public required string AccessKeyId { get; init; }

    public required string SecretAccessKey { get; init; }

    /// <summary>How long an issued URL keeps working.</summary>
    public required TimeSpan Lifetime { get; init; }
}

/// <summary>
/// <see cref="IMediaUrlSigner"/> for any S3-compatible store: an AWS Signature Version 4 query-string signature
/// (presigned <c>GET</c>) computed locally, with no network call and no SDK. The URL names the host, bucket and
/// object key, never the credential: only the access key id and the signature appear in it (ADR-072).
/// </summary>
public sealed partial class S3PresignedUrlSigner : IMediaUrlSigner
{
    public const int MinLifetimeSeconds = 60;
    public const int MaxLifetimeSeconds = 3600;

    private const int MaxKeyBytes = 1024;
    private const string Algorithm = "AWS4-HMAC-SHA256";
    private const string Service = "s3";

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    private readonly S3StorageOptions _options;
    private readonly int _lifetimeSeconds;

    public S3PresignedUrlSigner(S3StorageOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (!options.Endpoint.IsAbsoluteUri || options.Endpoint.Scheme is not ("https" or "http")
            || options.Endpoint.AbsolutePath != "/" || options.Endpoint.Query.Length > 0 || options.Endpoint.UserInfo.Length > 0)
        {
            throw new ArgumentException("The storage endpoint must be an http(s) origin with no path, query or credentials.", nameof(options));
        }

        if (!IsValidBucket(options.Bucket) || !IsValidRegion(options.Region)
            || string.IsNullOrWhiteSpace(options.AccessKeyId) || string.IsNullOrWhiteSpace(options.SecretAccessKey))
        {
            throw new ArgumentException("The storage bucket, region or credentials are invalid.", nameof(options));
        }

        var seconds = options.Lifetime.TotalSeconds;
        if (seconds is < MinLifetimeSeconds or > MaxLifetimeSeconds || seconds != Math.Floor(seconds))
        {
            throw new ArgumentException(
                $"The URL lifetime must be a whole number of seconds between {MinLifetimeSeconds} and {MaxLifetimeSeconds}.", nameof(options));
        }

        _options = options;
        _lifetimeSeconds = (int)seconds;
    }

    public static bool IsValidBucket(string? bucket) => bucket is not null && BucketPattern().IsMatch(bucket);

    public static bool IsValidRegion(string? region) => region is not null && RegionPattern().IsMatch(region);

    public SignedMediaUrl? Sign(string storageKey, DateTimeOffset issuedAt)
    {
        if (!IsSignableKey(storageKey))
        {
            return null;
        }

        // The signature has one-second resolution, so truncate and report the expiry that was actually signed.
        var issued = DateTimeOffset.FromUnixTimeSeconds(issuedAt.ToUnixTimeSeconds());
        var path = $"/{_options.Bucket}/{EncodePath(storageKey)}";
        var url = Presign("GET", _options.Endpoint, path, _options.Region, _options.AccessKeyId, _options.SecretAccessKey, issued, _lifetimeSeconds);
        return new SignedMediaUrl(url, issued.AddSeconds(_lifetimeSeconds));
    }

    /// <summary>
    /// A key the server will sign: a relative, slash-separated path of non-empty segments, valid UTF-8, at most
    /// 1024 bytes, without <c>.</c> or <c>..</c> segments, backslashes or control characters.
    /// </summary>
    public static bool IsSignableKey(string? key)
    {
        if (string.IsNullOrEmpty(key) || key.Length > MaxKeyBytes || key[0] == '/' || key[^1] == '/')
        {
            return false;
        }

        if (key.Any(c => c == '\\' || char.IsControl(c)))
        {
            return false;
        }

        try
        {
            if (StrictUtf8.GetByteCount(key) > MaxKeyBytes)
            {
                return false;
            }
        }
        catch (EncoderFallbackException)
        {
            return false;
        }

        return key.Split('/').All(segment => segment.Length > 0 && segment is not ("." or ".."));
    }

    /// <summary>
    /// AWS Signature Version 4 for a presigned request with an unsigned payload and only the <c>host</c> header signed.
    /// <paramref name="canonicalPath"/> is the already percent-encoded absolute path.
    /// </summary>
    internal static Uri Presign(
        string method, Uri origin, string canonicalPath, string region, string accessKeyId, string secretAccessKey,
        DateTimeOffset issuedAt, int expiresSeconds)
    {
        var utc = issuedAt.ToUniversalTime();
        var timestamp = utc.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        var date = utc.ToString("yyyyMMdd", CultureInfo.InvariantCulture);
        var scope = $"{date}/{region}/{Service}/aws4_request";
        var authority = origin.Authority;

        // Query names are already in the byte order SigV4 requires (all start with "X-Amz-").
        var query = string.Create(CultureInfo.InvariantCulture,
            $"X-Amz-Algorithm={Algorithm}&X-Amz-Credential={EncodeComponent($"{accessKeyId}/{scope}")}&X-Amz-Date={timestamp}&X-Amz-Expires={expiresSeconds}&X-Amz-SignedHeaders=host");

        var canonicalRequest = $"{method}\n{canonicalPath}\n{query}\nhost:{authority}\n\nhost\nUNSIGNED-PAYLOAD";
        var stringToSign = $"{Algorithm}\n{timestamp}\n{scope}\n{Hex(SHA256.HashData(Encoding.UTF8.GetBytes(canonicalRequest)))}";

        var signingKey = Hmac(Hmac(Hmac(Hmac(Encoding.UTF8.GetBytes("AWS4" + secretAccessKey), date), region), Service), "aws4_request");
        var signature = Hex(Hmac(signingKey, stringToSign));

        return new Uri($"{origin.Scheme}://{authority}{canonicalPath}?{query}&X-Amz-Signature={signature}", UriKind.Absolute);
    }

    private static string EncodePath(string key) => string.Join('/', key.Split('/').Select(EncodeComponent));

    /// <summary>RFC 3986 unreserved characters stay; every other UTF-8 byte becomes <c>%XX</c> (upper case).</summary>
    private static string EncodeComponent(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (var b in Encoding.UTF8.GetBytes(value))
        {
            if (b is (>= (byte)'A' and <= (byte)'Z') or (>= (byte)'a' and <= (byte)'z') or (>= (byte)'0' and <= (byte)'9')
                or (byte)'-' or (byte)'_' or (byte)'.' or (byte)'~')
            {
                builder.Append((char)b);
            }
            else
            {
                builder.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
            }
        }

        return builder.ToString();
    }

    private static byte[] Hmac(byte[] key, string data) => HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(data));

    private static string Hex(byte[] bytes) => Convert.ToHexStringLower(bytes);

    // S3 bucket naming rules: 3..63 characters, lower-case letters, digits, hyphens and dots, alphanumeric at both ends.
    [GeneratedRegex(@"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z")]
    private static partial Regex BucketPattern();

    [GeneratedRegex(@"^[a-z0-9-]{1,30}\z")]
    private static partial Regex RegionPattern();
}
