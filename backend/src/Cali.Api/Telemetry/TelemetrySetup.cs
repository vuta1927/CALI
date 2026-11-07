using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

namespace Cali.Api.Telemetry;

public static class TelemetrySetup
{
    public const string ServiceName = "cali-api";

    /// <summary>
    /// Tracing + metrics. <c>Telemetry:Exporter</c> = <c>none</c> (default) | <c>console</c> | <c>otlp</c>.
    /// OTLP endpoint/headers come from the standard <c>OTEL_EXPORTER_OTLP_*</c> env vars.
    /// No request/response bodies or headers are recorded.
    /// </summary>
    public static IServiceCollection AddCaliTelemetry(this IServiceCollection services, IConfiguration configuration)
    {
        var exporter = (configuration["Telemetry:Exporter"] ?? "none").Trim().ToUpperInvariant();

        services.AddOpenTelemetry()
            .ConfigureResource(resource => resource.AddService(ServiceName))
            .WithTracing(tracing =>
            {
                tracing
                    .AddAspNetCoreInstrumentation(o =>
                    {
                        o.Filter = http => !http.Request.Path.StartsWithSegments("/health", StringComparison.OrdinalIgnoreCase);
                        o.RecordException = false;
                    })
                    .AddSource("Npgsql");

                switch (exporter)
                {
                    case "CONSOLE": tracing.AddConsoleExporter(); break;
                    case "OTLP": tracing.AddOtlpExporter(); break;
                }
            })
            .WithMetrics(metrics =>
            {
                metrics.AddAspNetCoreInstrumentation().AddMeter("Npgsql");

                switch (exporter)
                {
                    case "CONSOLE": metrics.AddConsoleExporter(); break;
                    case "OTLP": metrics.AddOtlpExporter(); break;
                }
            });

        return services;
    }
}
