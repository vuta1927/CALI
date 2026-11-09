using System.Security.Cryptography;
using Cali.Application.Sync;
using Cali.Infrastructure.Auth;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Cali.Api.Sync;

/// <summary>Registers the pull feed (BE-004, ADR-070): cursor signing key, retention window and the use case.</summary>
public static class SyncPullSetup
{
    /// <summary>Env: <c>Sync__CursorSigningKey</c>. Base64, at least <see cref="SyncCursorCodec.MinKeyBytes"/> bytes. Secret; never committed.</summary>
    public const string CursorKeyConfigKey = "Sync:CursorSigningKey";

    /// <summary>Env: <c>Sync__ChangeLogRetentionDays</c>. A cursor older than this needs a full resync.</summary>
    public const string RetentionConfigKey = "Sync:ChangeLogRetentionDays";

    // Development derives its cursor key from the dev token key so cursors survive a restart without one more secret.
    private static readonly byte[] DevKeyLabel = "cali.sync.cursor.v1"u8.ToArray();

    public static IServiceCollection AddCaliSyncPull(this IServiceCollection services)
    {
        services.TryAddSingleton(TimeProvider.System);
        services.AddScoped<ISyncReader, Cali.Infrastructure.Persistence.SyncReader>();
        services.AddSingleton(sp => new SyncCursorCodec(ResolveKey(
            sp.GetRequiredService<IConfiguration>(), sp.GetRequiredService<IHostEnvironment>(),
            sp.GetRequiredService<ILoggerFactory>().CreateLogger(typeof(SyncPullSetup)))));
        services.AddSingleton(sp => new SyncPullSettings(ResolveRetention(sp.GetRequiredService<IConfiguration>())));
        services.AddScoped<PullChanges>();
        return services;
    }

    internal static byte[] ResolveKey(IConfiguration configuration, IHostEnvironment environment, ILogger logger)
    {
        var configured = configuration[CursorKeyConfigKey];
        if (!string.IsNullOrWhiteSpace(configured))
        {
            if (!TryFromBase64(configured, out var key) || key.Length < SyncCursorCodec.MinKeyBytes)
            {
                throw new InvalidOperationException(
                    $"{CursorKeyConfigKey} must be base64 and decode to at least {SyncCursorCodec.MinKeyBytes} bytes.");
            }

            return key;
        }

        if (!environment.IsDevelopment())
        {
            throw new InvalidOperationException($"{CursorKeyConfigKey} is not configured (env Sync__CursorSigningKey).");
        }

        if (DevSigningKey.TryParse(configuration[DevTokenDefaults.SigningKeyConfigKey], out var devKey, out _))
        {
            return HMACSHA256.HashData(devKey, DevKeyLabel);
        }

        logger.LogWarning("{Key} is not configured; using a per-process key, so sync cursors stop working when the API restarts.", CursorKeyConfigKey);
        return RandomNumberGenerator.GetBytes(SyncCursorCodec.MinKeyBytes);
    }

    internal static TimeSpan ResolveRetention(IConfiguration configuration)
    {
        var raw = configuration[RetentionConfigKey];
        if (string.IsNullOrWhiteSpace(raw))
        {
            return TimeSpan.FromDays(SyncPullSettings.DefaultRetentionDays);
        }

        if (!int.TryParse(raw, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var days) || days < 1)
        {
            throw new InvalidOperationException($"{RetentionConfigKey} must be a whole number of days, at least 1.");
        }

        return TimeSpan.FromDays(days);
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
}
