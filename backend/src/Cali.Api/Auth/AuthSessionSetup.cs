using System.Globalization;
using System.Security.Cryptography;
using Cali.Application.Identity;
using Cali.Infrastructure.Auth;
using Cali.Infrastructure.Persistence;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Cali.Api.Auth;

/// <summary>Everything Sign in with Apple and refresh need from configuration, resolved once (ADR-071).</summary>
/// <param name="AccessTokenKey">HS256 key that signs and verifies CALI access tokens. Secret.</param>
/// <param name="AppleClientId">Expected <c>aud</c> of Apple identity tokens (the app bundle id); null disables Apple sign-in.</param>
public sealed record AuthTokenSettings(
    byte[] AccessTokenKey,
    string Audience,
    TimeSpan AccessLifetime,
    TimeSpan RefreshLifetime,
    TimeSpan FamilyLifetime,
    string? AppleClientId,
    Uri AppleKeysUrl);

/// <summary>Registers <c>POST /v1/auth/apple</c> and <c>/v1/auth/refresh</c> (BE-005, ADR-071) and the settings they share with bearer validation.</summary>
public static class AuthSessionSetup
{
    /// <summary>Env: <c>Auth__AccessTokenSigningKey</c>. Base64, at least <see cref="AccessTokenDefaults.MinKeyBytes"/> bytes. Secret; never committed.</summary>
    public const string AccessTokenKeyConfigKey = "Auth:AccessTokenSigningKey";

    /// <summary>Env: <c>Auth__AccessTokenMinutes</c>. Default 15.</summary>
    public const string AccessTokenMinutesConfigKey = "Auth:AccessTokenMinutes";

    /// <summary>Env: <c>Auth__RefreshTokenDays</c>. Default 60. Sliding: each rotation starts a new window.</summary>
    public const string RefreshTokenDaysConfigKey = "Auth:RefreshTokenDays";

    /// <summary>Env: <c>Auth__RefreshFamilyMaxDays</c>. Default 180. Absolute cap since sign-in.</summary>
    public const string RefreshFamilyMaxDaysConfigKey = "Auth:RefreshFamilyMaxDays";

    /// <summary>Env: <c>Auth__Apple__ClientId</c>. The app bundle id (Apple <c>aud</c>). Required outside Development.</summary>
    public const string AppleClientIdConfigKey = "Auth:Apple:ClientId";

    /// <summary>Env: <c>Auth__Apple__KeysUrl</c>. HTTPS only; defaults to Apple's JWKS endpoint.</summary>
    public const string AppleKeysUrlConfigKey = "Auth:Apple:KeysUrl";

    public const int DefaultAccessTokenMinutes = 15;
    public const int DefaultRefreshTokenDays = 60;
    public const int DefaultRefreshFamilyMaxDays = 180;

    // Development derives the access key from the dev token key so tokens survive a restart without one more secret.
    private static readonly byte[] DevKeyLabel = "cali.auth.access.v1"u8.ToArray();

    /// <summary>Settings only: what bearer validation needs. Safe to call more than once.</summary>
    public static IServiceCollection AddCaliAuthTokenSettings(this IServiceCollection services)
    {
        services.TryAddSingleton(sp => Resolve(
            sp.GetRequiredService<IConfiguration>(), sp.GetRequiredService<IHostEnvironment>(),
            sp.GetRequiredService<ILoggerFactory>().CreateLogger(typeof(AuthSessionSetup))));
        return services;
    }

    public static IServiceCollection AddCaliAuthSessions(this IServiceCollection services)
    {
        services.AddCaliAuthTokenSettings();
        services.TryAddSingleton(TimeProvider.System);

        // A misconfigured key or client id must stop the host at startup, not surface as 500s on the first request.
        services.AddHostedService<AuthSettingsStartupCheck>();

        services.AddHttpClient(AppleKeySetOptions.HttpClientName, client =>
        {
            client.Timeout = TimeSpan.FromSeconds(5);
            client.MaxResponseContentBufferSize = AppleKeySetOptions.MaxResponseBytes;
        });
        services.AddSingleton<IAppleKeySetProvider>(sp => new HttpAppleKeySetProvider(
            sp.GetRequiredService<IHttpClientFactory>(),
            new AppleKeySetOptions(sp.GetRequiredService<AuthTokenSettings>().AppleKeysUrl),
            sp.GetRequiredService<TimeProvider>(),
            sp.GetRequiredService<ILogger<HttpAppleKeySetProvider>>()));
        services.AddSingleton<IAppleIdentityTokenValidator>(sp => new AppleIdentityTokenValidator(
            sp.GetRequiredService<IAppleKeySetProvider>(),
            new AppleIdentityOptions(sp.GetRequiredService<AuthTokenSettings>().AppleClientId),
            sp.GetRequiredService<TimeProvider>()));
        services.AddSingleton<IAccessTokenIssuer>(sp =>
        {
            var settings = sp.GetRequiredService<AuthTokenSettings>();
            return new AccessTokenIssuer(settings.AccessTokenKey, settings.Audience, settings.AccessLifetime, sp.GetRequiredService<TimeProvider>());
        });
        services.AddSingleton(sp =>
        {
            var settings = sp.GetRequiredService<AuthTokenSettings>();
            return new SessionLifetimes(settings.RefreshLifetime, settings.FamilyLifetime);
        });
        services.AddScoped<IAuthStore, AuthStore>();
        services.AddScoped<AuthenticateWithApple>();
        services.AddScoped<RefreshSession>();
        return services;
    }

    internal static AuthTokenSettings Resolve(IConfiguration configuration, IHostEnvironment environment, ILogger logger)
    {
        var accessMinutes = ReadInt(configuration, AccessTokenMinutesConfigKey, DefaultAccessTokenMinutes, 1, 60);
        var refreshDays = ReadInt(configuration, RefreshTokenDaysConfigKey, DefaultRefreshTokenDays, 1, 365);
        var familyDays = ReadInt(configuration, RefreshFamilyMaxDaysConfigKey, DefaultRefreshFamilyMaxDays, 1, 730);
        if (familyDays < refreshDays)
        {
            throw new InvalidOperationException($"{RefreshFamilyMaxDaysConfigKey} must not be less than {RefreshTokenDaysConfigKey}.");
        }

        var audience = configuration[AuthenticationSetup.AudienceConfigKey] is { Length: > 0 } a ? a : DevTokenDefaults.Audience;

        string? clientId = null;
        if (configuration[AppleClientIdConfigKey] is { } rawClientId && !string.IsNullOrWhiteSpace(rawClientId))
        {
            clientId = rawClientId.Trim();
        }
        else if (!environment.IsDevelopment())
        {
            throw new InvalidOperationException($"{AppleClientIdConfigKey} is not configured (env Auth__Apple__ClientId).");
        }
        else
        {
            logger.LogWarning("{Key} is not configured; Sign in with Apple is disabled.", AppleClientIdConfigKey);
        }

        var keysUrl = AppleKeySetOptions.DefaultUrl;
        if (configuration[AppleKeysUrlConfigKey] is { } rawUrl && !string.IsNullOrWhiteSpace(rawUrl))
        {
            if (!Uri.TryCreate(rawUrl.Trim(), UriKind.Absolute, out keysUrl) || keysUrl.Scheme != Uri.UriSchemeHttps)
            {
                throw new InvalidOperationException($"{AppleKeysUrlConfigKey} must be an absolute https URL.");
            }
        }

        return new AuthTokenSettings(
            ResolveKey(configuration, environment, logger),
            audience,
            TimeSpan.FromMinutes(accessMinutes),
            TimeSpan.FromDays(refreshDays),
            TimeSpan.FromDays(familyDays),
            clientId,
            keysUrl);
    }

    internal static byte[] ResolveKey(IConfiguration configuration, IHostEnvironment environment, ILogger logger)
    {
        var configured = configuration[AccessTokenKeyConfigKey];
        if (!string.IsNullOrWhiteSpace(configured))
        {
            if (!TryFromBase64(configured, out var key) || key.Length < AccessTokenDefaults.MinKeyBytes)
            {
                // The value is never echoed.
                throw new InvalidOperationException(
                    $"{AccessTokenKeyConfigKey} must be base64 and decode to at least {AccessTokenDefaults.MinKeyBytes} bytes.");
            }

            return key;
        }

        if (!environment.IsDevelopment())
        {
            throw new InvalidOperationException($"{AccessTokenKeyConfigKey} is not configured (env Auth__AccessTokenSigningKey).");
        }

        if (DevSigningKey.TryParse(configuration[DevTokenDefaults.SigningKeyConfigKey], out var devKey, out _))
        {
            return HMACSHA256.HashData(devKey, DevKeyLabel);
        }

        logger.LogWarning("{Key} is not configured; using a per-process key, so CALI access tokens stop working when the API restarts.", AccessTokenKeyConfigKey);
        return RandomNumberGenerator.GetBytes(AccessTokenDefaults.MinKeyBytes);
    }

    private static int ReadInt(IConfiguration configuration, string key, int fallback, int min, int max)
    {
        var raw = configuration[key];
        if (string.IsNullOrWhiteSpace(raw))
        {
            return fallback;
        }

        if (!int.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out var value) || value < min || value > max)
        {
            throw new InvalidOperationException($"{key} must be a whole number between {min} and {max}.");
        }

        return value;
    }

    private static bool TryFromBase64(string value, out byte[] key)
    {
        try
        {
            key = Convert.FromBase64String(value.Trim());
            return true;
        }
        catch (FormatException)
        {
            key = [];
            return false;
        }
    }

    private sealed class AuthSettingsStartupCheck(AuthTokenSettings settings) : IHostedService
    {
        // Resolving AuthTokenSettings (constructor injection) is the check; it throws on a bad configuration.
        public Task StartAsync(CancellationToken cancellationToken) => settings.AccessTokenKey.Length >= AccessTokenDefaults.MinKeyBytes
            ? Task.CompletedTask
            : throw new InvalidOperationException("Access token key is too short.");

        public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    }
}
