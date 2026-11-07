using Microsoft.Extensions.Options;

namespace Cali.Worker;

public sealed class HeartbeatOptions
{
    public const string SectionName = "Worker:Heartbeat";

    public TimeSpan Interval { get; set; } = TimeSpan.FromSeconds(30);
}

/// <summary>
/// Skeleton background service: logs a heartbeat and stops promptly on shutdown.
/// It deliberately performs no job processing.
/// TODO(AI-001): replace with the ai_jobs lease/claim loop (M3). Expiry: remove when AI-001 lands.
/// </summary>
public sealed class HeartbeatWorker(ILogger<HeartbeatWorker> logger, IOptions<HeartbeatOptions> options, TimeProvider timeProvider)
    : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var interval = options.Value.Interval > TimeSpan.Zero ? options.Value.Interval : TimeSpan.FromSeconds(30);
        logger.LogInformation("Worker started; heartbeat every {Interval}", interval);

        while (!stoppingToken.IsCancellationRequested)
        {
            logger.LogInformation("Worker heartbeat at {UtcNow:O}", timeProvider.GetUtcNow());
            try
            {
                await Task.Delay(interval, timeProvider, stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
        }

        logger.LogInformation("Worker stopping");
    }
}
