using System.Globalization;
using System.Threading.RateLimiting;
using Cali.Api.Auth;
using Cali.Api.Errors;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Options;

namespace Cali.Api.RateLimiting;

public static class RateLimitPolicies
{
    public const string Auth = "auth";
    public const string Sync = "sync";
    public const string Ai = "ai";

    /// <summary>Anonymous read-only publisher content (catalog, criteria config): per client IP.</summary>
    public const string Public = "public";
}

public sealed class FixedWindowSettings
{
    public int PermitLimit { get; set; }
    public int WindowSeconds { get; set; }
}

/// <summary>Bound from <c>RateLimiting</c>; defaults apply when configuration omits a policy.</summary>
public sealed class RateLimitingSettings
{
    public const string SectionName = "RateLimiting";

    public FixedWindowSettings Auth { get; set; } = new() { PermitLimit = 10, WindowSeconds = 60 };
    public FixedWindowSettings Sync { get; set; } = new() { PermitLimit = 60, WindowSeconds = 60 };
    public FixedWindowSettings Ai { get; set; } = new() { PermitLimit = 5, WindowSeconds = 60 };
    public FixedWindowSettings Public { get; set; } = new() { PermitLimit = 120, WindowSeconds = 60 };
}

public static class RateLimitingSetup
{
    public static IServiceCollection AddCaliRateLimiting(this IServiceCollection services)
    {
        services.AddOptions<RateLimitingSettings>().BindConfiguration(RateLimitingSettings.SectionName);

        services.AddRateLimiter(options =>
        {
            options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;

            // Auth endpoints are anonymous: partition by client IP.
            options.AddPolicy(RateLimitPolicies.Auth, http =>
                FixedWindow($"ip:{ClientIp(http)}", Settings(http).Auth));

            // Anonymous publisher content (docs/11 §2): per client IP, separate budget from auth.
            options.AddPolicy(RateLimitPolicies.Public, http =>
                FixedWindow($"public-ip:{ClientIp(http)}", Settings(http).Public));

            // Authenticated endpoints: partition by token subject (falls back to IP).
            options.AddPolicy(RateLimitPolicies.Sync, http => FixedWindow(UserOrIp(http), Settings(http).Sync));
            options.AddPolicy(RateLimitPolicies.Ai, http => FixedWindow(UserOrIp(http), Settings(http).Ai));

            options.OnRejected = async (context, cancellationToken) =>
            {
                if (context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter))
                {
                    context.HttpContext.Response.Headers.RetryAfter =
                        ((int)Math.Ceiling(retryAfter.TotalSeconds)).ToString(CultureInfo.InvariantCulture);
                }

                await ProblemWriter.WriteAsync(context.HttpContext, StatusCodes.Status429TooManyRequests,
                    ProblemCodes.RateLimited, "Too many requests.").ConfigureAwait(false);
            };
        });

        return services;
    }

    private static RateLimitingSettings Settings(HttpContext http) =>
        http.RequestServices.GetRequiredService<IOptionsMonitor<RateLimitingSettings>>().CurrentValue;

    private static RateLimitPartition<string> FixedWindow(string key, FixedWindowSettings settings) =>
        RateLimitPartition.GetFixedWindowLimiter(key, _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = Math.Max(1, settings.PermitLimit),
            Window = TimeSpan.FromSeconds(Math.Max(1, settings.WindowSeconds)),
            QueueLimit = 0,
            AutoReplenishment = true,
        });

    private static string UserOrIp(HttpContext http) =>
        CurrentUserClaims.TryGetUserId(http.User, out var id) ? $"user:{id:D}" : $"ip:{ClientIp(http)}";

    // NOTE: behind a reverse proxy configure ForwardedHeaders (known proxies) before relying on this (BE-004 / deploy).
    private static string ClientIp(HttpContext http) => http.Connection.RemoteIpAddress?.ToString() ?? "unknown";
}
