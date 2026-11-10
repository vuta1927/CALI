using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text;

namespace Cali.Application.Identity;

/// <summary>
/// Opaque refresh token: 32 random bytes as base64url (43 characters). The server keeps only the SHA-256 of the
/// token, so a database read cannot be replayed as a session. The token has 256 bits of entropy, so a plain
/// (unsalted, fast) hash is enough and lets the row be found by an index lookup.
/// </summary>
public static class RefreshTokenSecret
{
    public const int Bytes = 32;
    public const int EncodedLength = 43;

    public static string Create() => Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(Bytes));

    /// <summary>The stored form of a token (SHA-256 over its encoded text).</summary>
    public static byte[] Hash(string token) => SHA256.HashData(Encoding.UTF8.GetBytes(token));

    /// <summary>False for anything that cannot be a token this server issued, so it never reaches the database.</summary>
    public static bool IsWellFormed(string? token) =>
        token is { Length: EncodedLength }
        && Base64Url.IsValid(token)
        && Base64Url.DecodeFromChars(token).Length == Bytes
        // Canonical form only: the last character carries 4 padding bits that must be zero, otherwise two
        // different strings would decode to the same bytes.
        && Base64Url.EncodeToString(Base64Url.DecodeFromChars(token)) == token;
}

/// <summary>
/// Sign in with Apple nonce convention (ADR-071). The app sends Apple the lowercase hex SHA-256 of a fresh random
/// string and sends the API the raw string. Apple copies what it was given into the identity token's <c>nonce</c>
/// claim, so the server recomputes the hash of the raw nonce and compares it with that claim.
/// </summary>
public static class AppleNonce
{
    public static string ExpectedClaim(string rawNonce) => Convert.ToHexStringLower(Hash(rawNonce));

    /// <summary>What the server remembers to refuse a second sign-in with the same nonce.</summary>
    public static byte[] Hash(string rawNonce) => SHA256.HashData(Encoding.UTF8.GetBytes(rawNonce));
}
