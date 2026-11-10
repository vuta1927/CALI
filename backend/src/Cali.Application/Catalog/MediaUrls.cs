namespace Cali.Application.Catalog;

/// <summary>A short-lived, read-only URL for one stored media object and the instant it stops working.</summary>
public sealed record SignedMediaUrl(Uri Url, DateTimeOffset ExpiresAt);

/// <summary>
/// Turns the server-internal <c>storage_key</c> of a public, reviewed media row into a URL the client can fetch
/// without credentials (ADR-072). Implementations hide the object store: the storage key, the bucket and every
/// credential stay on the server, and callers never see anything but the signed URL.
/// </summary>
public interface IMediaUrlSigner
{
    /// <summary>
    /// A URL valid from <paramref name="issuedAt"/> for the signer's lifetime, or null when this deployment has no
    /// object storage or the key is not one the server would ever sign (so a bad row degrades to "no URL", not a 500).
    /// </summary>
    SignedMediaUrl? Sign(string storageKey, DateTimeOffset issuedAt);
}

/// <summary>Used when no object storage is configured (Development only): the catalog keeps returning <c>url: null</c>.</summary>
public sealed class NoMediaUrlSigner : IMediaUrlSigner
{
    public SignedMediaUrl? Sign(string storageKey, DateTimeOffset issuedAt) => null;
}
