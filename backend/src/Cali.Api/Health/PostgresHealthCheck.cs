using Microsoft.Extensions.Diagnostics.HealthChecks;
using Npgsql;

namespace Cali.Api.Health;

/// <summary>Readiness: the database accepts a connection and answers <c>SELECT 1</c> within the timeout.</summary>
internal sealed class PostgresHealthCheck(IServiceProvider services) : IHealthCheck
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(3);

    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(Timeout);
        try
        {
            var dataSource = services.GetRequiredService<NpgsqlDataSource>();
            await using var command = dataSource.CreateCommand("SELECT 1");
            await command.ExecuteScalarAsync(cts.Token).ConfigureAwait(false);
            return HealthCheckResult.Healthy();
        }
#pragma warning disable CA1031 // Any failure means "not ready"; details are logged by the health check service, not returned.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            return HealthCheckResult.Unhealthy("Database unavailable.", ex);
        }
    }
}
