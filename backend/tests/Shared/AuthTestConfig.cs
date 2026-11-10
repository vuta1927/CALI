using System.Security.Cryptography;

namespace Cali.Tests.Shared;

/// <summary>
/// Settings a host needs outside Development: since BE-005 the API refuses to start without an access token
/// signing key and the Apple client id (ADR-071). Tests that run as Production merge these in.
/// </summary>
internal static class AuthTestConfig
{
    public const string AccessKeySetting = "Auth:AccessTokenSigningKey";
    public const string ClientIdSetting = "Auth:Apple:ClientId";

    public static string NewAccessKey() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));

    /// <summary>The two required settings, with a fresh random key.</summary>
    public static Dictionary<string, string?> Required() => new()
    {
        [AccessKeySetting] = NewAccessKey(),
        [ClientIdSetting] = AppleTestTokens.ClientId,
    };

    /// <summary><paramref name="settings"/> plus <see cref="Required"/> (the caller's values win).</summary>
    public static Dictionary<string, string?> With(IEnumerable<KeyValuePair<string, string?>> settings)
    {
        var merged = Required();
        foreach (var (key, value) in settings)
        {
            merged[key] = value;
        }

        return merged;
    }
}
