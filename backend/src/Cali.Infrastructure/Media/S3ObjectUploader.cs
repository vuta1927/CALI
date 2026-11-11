using System.Net.Http.Headers;
using Cali.Application.VoicePublishing;

namespace Cali.Infrastructure.Media;

/// <summary>
/// Uploads one object with a presigned SigV4 <c>PUT</c> (the same signature the read URLs use, ADR-072), so no SDK is
/// needed. Used by the publisher tool only: its credential must be allowed to write, unlike the API's read-only one.
/// </summary>
public sealed class S3ObjectUploader(HttpClient http, S3StorageOptions options, TimeProvider time) : IObjectUploader
{
    private const int UploadUrlSeconds = 300;

    public async Task PutAsync(string storageKey, byte[] content, string contentType, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(content);
        if (!S3PresignedUrlSigner.IsSignableKey(storageKey))
        {
            throw new ArgumentException("The storage key is not a valid object key.", nameof(storageKey));
        }

        var path = $"/{options.Bucket}/{S3PresignedUrlSigner.EncodePath(storageKey)}";
        var url = S3PresignedUrlSigner.Presign(
            "PUT", options.Endpoint, path, options.Region, options.AccessKeyId, options.SecretAccessKey,
            DateTimeOffset.FromUnixTimeSeconds(time.GetUtcNow().ToUnixTimeSeconds()), UploadUrlSeconds);

        using var body = new ByteArrayContent(content);
        body.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        using var response = await http.PutAsync(url, body, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            // The URL carries the signature; report only the key and status.
            throw new HttpRequestException($"Upload of '{storageKey}' failed with HTTP {(int)response.StatusCode}.", null, response.StatusCode);
        }
    }
}
