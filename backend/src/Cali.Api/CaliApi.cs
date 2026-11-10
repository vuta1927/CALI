using Cali.Api.Auth;
using Cali.Api.Endpoints;
using Cali.Api.Errors;
using Cali.Api.Health;
using Cali.Api.RateLimiting;
using Cali.Api.Telemetry;
using Cali.Application.Catalog;
using Cali.Application.Identity;
using Cali.Application.Plans;
using Cali.Api.Sync;
using Cali.Application.Sync;
using Cali.Infrastructure;
using Cali.Infrastructure.Persistence.Migrations;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.Extensions.Options;

namespace Cali.Api;

internal static class CaliApi
{
    public const string ReadyTag = "ready";

    public static WebApplication Build(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);
        ConfigureServices(builder);
        var app = builder.Build();
        ConfigurePipeline(app);
        return app;
    }

    private static void ConfigureServices(WebApplicationBuilder builder)
    {
        var services = builder.Services;

        // Logging: no HTTP body/header logging middleware is registered; IdentityModel PII logging stays off.
        services.AddProblemDetails(options =>
            options.CustomizeProblemDetails = context => ProblemDetailsEnricher.Enrich(context.ProblemDetails, context.HttpContext));

        services.AddCaliInfrastructure();
        services.AddScoped<GetCurrentUserProfile>();
        services.AddScoped<ListExercises>();
        services.AddScoped<GetExercise>();
        services.AddScoped<GetCriteriaConfig>();
        services.AddScoped<ListPlans>();
        services.AddScoped<CreatePlan>();
        services.AddScoped<SyncPush>();
        services.AddCaliSyncPull();
        services.AddCaliAuthentication();
        services.AddCaliAuthSessions();
        services.AddCaliRateLimiting();
        services.AddCaliTelemetry(builder.Configuration);

        services.AddHealthChecks().AddCheck<PostgresHealthCheck>("postgres", tags: [ReadyTag]);

        services.Configure<HostOptions>(o => o.ShutdownTimeout = TimeSpan.FromSeconds(20));
    }

    private static void ConfigurePipeline(WebApplication app)
    {
        app.UseExceptionHandler(new ExceptionHandlerOptions
        {
            StatusCodeSelector = ex => ex is BadHttpRequestException bad ? bad.StatusCode : StatusCodes.Status500InternalServerError,
        });
        app.UseStatusCodePages();

        app.UseAuthentication();
        app.UseAuthorization();
        app.UseRateLimiter();

        // Liveness: process is up; no dependencies checked.
        app.MapHealthChecks("/health/live", new HealthCheckOptions { Predicate = _ => false })
            .AllowAnonymous().DisableRateLimiting();
        // Readiness: database reachable.
        app.MapHealthChecks("/health/ready", new HealthCheckOptions { Predicate = c => c.Tags.Contains(ReadyTag) })
            .AllowAnonymous().DisableRateLimiting();

        app.MapAuthEndpoints();
        app.MapMeEndpoints();
        app.MapCatalogEndpoints();
        app.MapPlanEndpoints();
        app.MapSyncEndpoints();
    }

    /// <summary>Development only, and only when <c>Migrations:ApplyOnStartup</c> is true.</summary>
    public static bool ApplyStartupMigrations(WebApplication app)
    {
        var options = app.Services.GetRequiredService<IOptions<MigrationOptions>>().Value;
        if (!app.Environment.IsDevelopment() || !options.ApplyOnStartup)
        {
            return true;
        }

        return Migrate(app.Services, app.Configuration, app.Environment, options);
    }

    public static int RunMigrateCommand(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);
        builder.Services.AddCaliInfrastructure();
        using var app = builder.Build();
        var options = app.Services.GetRequiredService<IOptions<MigrationOptions>>().Value;
        return Migrate(app.Services, app.Configuration, app.Environment, options) ? 0 : 1;
    }

    private static bool Migrate(IServiceProvider services, IConfiguration configuration, IHostEnvironment environment, MigrationOptions options)
    {
        var logger = services.GetRequiredService<ILoggerFactory>().CreateLogger("Cali.Migrations");
        var connectionString = configuration.GetConnectionString(DependencyInjection.ConnectionStringName);
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            logger.LogCritical("Connection string '{Name}' is not configured; cannot migrate", DependencyInjection.ConnectionStringName);
            return false;
        }

        var scripts = MigrationScripts.ResolveDirectory(options.ScriptsPath, environment.ContentRootPath);
        var result = services.GetRequiredService<DatabaseMigrator>()
            .Run(connectionString, scripts, includeDevelopmentScripts: environment.IsDevelopment(), options.JournalTable);
        return result.Successful;
    }
}
