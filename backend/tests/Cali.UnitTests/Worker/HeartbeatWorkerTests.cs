using System.Collections.Concurrent;
using Cali.Worker;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Microsoft.Extensions.Time.Testing;

namespace Cali.UnitTests.Worker;

public sealed class HeartbeatWorkerTests
{
    [Fact]
    public async Task Logs_heartbeat_per_interval_and_stops_on_shutdown()
    {
        var time = new FakeTimeProvider(new DateTimeOffset(2026, 11, 7, 0, 0, 0, TimeSpan.Zero));
        var logger = new ListLogger<HeartbeatWorker>();
        using var worker = new HeartbeatWorker(logger,
            Options.Create(new HeartbeatOptions { Interval = TimeSpan.FromSeconds(10) }), time);

        await worker.StartAsync(CancellationToken.None);
        await WaitUntil(() => Heartbeats(logger) == 1);

        time.Advance(TimeSpan.FromSeconds(10));
        await WaitUntil(() => Heartbeats(logger) == 2);

        time.Advance(TimeSpan.FromSeconds(9));
        await Task.Delay(50);
        Heartbeats(logger).ShouldBe(2);

        using var stopTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await worker.StopAsync(stopTimeout.Token);

        var executeTask = worker.ExecuteTask ?? throw new ShouldAssertException("ExecuteTask was never started");
        executeTask.IsCompletedSuccessfully.ShouldBeTrue();
        logger.Messages.ShouldContain("Worker stopping");
    }

    private static int Heartbeats(ListLogger<HeartbeatWorker> logger) =>
        logger.Messages.Count(m => m.StartsWith("Worker heartbeat", StringComparison.Ordinal));

    private static async Task WaitUntil(Func<bool> condition)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (!condition())
        {
            await Task.Delay(10, timeout.Token);
        }
    }

    private sealed class ListLogger<T> : ILogger<T>
    {
        private readonly ConcurrentQueue<string> _messages = new();

        public IReadOnlyCollection<string> Messages => _messages.ToArray();

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter) =>
            _messages.Enqueue(formatter(state, exception));
    }
}
