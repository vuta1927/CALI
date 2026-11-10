using Cali.Api.Errors;
using Cali.Application.Abstractions;
using Cali.Infrastructure.Auth;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.IdentityModel.Tokens;

namespace Cali.Api.Auth;

public static class AuthenticationSetup
{
    public const string AudienceConfigKey = "Auth:Audience";

    public static IServiceCollection AddCaliAuthentication(this IServiceCollection services)
    {
        services.AddHttpContextAccessor();
        services.AddScoped<ICurrentUser, HttpCurrentUser>();

        services.AddCaliAuthTokenSettings();
        services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer();

        // Configured lazily so environment/configuration overrides (tests, user-secrets) are honoured.
        services.AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme)
            .Configure<IConfiguration, IHostEnvironment, ILoggerFactory, AuthTokenSettings>((options, configuration, environment, loggerFactory, tokens) =>
            {
                var issuers = TrustedIssuers.Build(configuration, environment, loggerFactory.CreateLogger(typeof(TrustedIssuers)), tokens);
                var audience = tokens.Audience;

                options.MapInboundClaims = false;
                options.RequireHttpsMetadata = !environment.IsDevelopment();
                options.SaveToken = false;
                options.IncludeErrorDetails = false;
                options.TokenValidationParameters = new TokenValidationParameters
                {
                    ValidateIssuer = true,
                    ValidIssuers = issuers.Select(i => i.Issuer).ToArray(),
                    ValidateAudience = true,
                    ValidAudience = audience,
                    ValidateLifetime = true,
                    RequireExpirationTime = true,
                    RequireSignedTokens = true,
                    ValidateIssuerSigningKey = true,
                    ClockSkew = TimeSpan.FromSeconds(30),
                    ValidAlgorithms = [SecurityAlgorithms.HmacSha256],
                    NameClaimType = CurrentUserClaims.Subject,
                    IssuerSigningKeyResolver = (_, securityToken, _, _) =>
                        issuers.FirstOrDefault(i => string.Equals(i.Issuer, securityToken?.Issuer, StringComparison.Ordinal))?.SigningKeys
                        ?? [],
                };

                options.Events = new JwtBearerEvents
                {
                    OnTokenValidated = context =>
                    {
                        if (!CurrentUserClaims.TryGetUserId(context.Principal, out _))
                        {
                            context.Fail("Token 'sub' must be a single non-empty UUID.");
                        }

                        return Task.CompletedTask;
                    },
                    OnChallenge = async context =>
                    {
                        context.HandleResponse();
                        var code = context.AuthenticateFailure is null ? "unauthorized" : "invalid_token";
                        context.Response.Headers.WWWAuthenticate = "Bearer";
                        // Failure reasons are intentionally not echoed to the client.
                        await ProblemWriter.WriteAsync(context.HttpContext, StatusCodes.Status401Unauthorized, code,
                            "Authentication is required.").ConfigureAwait(false);
                    },
                    OnForbidden = context => ProblemWriter.WriteAsync(context.HttpContext, StatusCodes.Status403Forbidden,
                        ProblemCodes.Forbidden, "You do not have access to this resource."),
                };
            });

        services.AddAuthorizationBuilder()
            .SetDefaultPolicy(new AuthorizationPolicyBuilder(JwtBearerDefaults.AuthenticationScheme).RequireAuthenticatedUser().Build())
            // Everything requires authentication unless explicitly marked AllowAnonymous (health endpoints).
            .SetFallbackPolicy(new AuthorizationPolicyBuilder(JwtBearerDefaults.AuthenticationScheme).RequireAuthenticatedUser().Build());

        return services;
    }
}

internal static class ProblemWriter
{
    public static async Task WriteAsync(HttpContext http, int status, string code, string title)
    {
        http.Response.StatusCode = status;
        var problems = http.RequestServices.GetRequiredService<IProblemDetailsService>();
        var problem = new ProblemDetails { Status = status, Title = title };
        problem.Extensions[ProblemDetailsEnricher.CodeKey] = code;
        await problems.WriteAsync(new ProblemDetailsContext { HttpContext = http, ProblemDetails = problem }).ConfigureAwait(false);
    }
}
