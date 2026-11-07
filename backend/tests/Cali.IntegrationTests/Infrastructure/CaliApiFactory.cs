using System.Collections.Concurrent;
using Cali.Tests.Shared;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace Cali.IntegrationTests.Infrastructure;

/// <summary>Hosts Cali.Api in-process for a given environment and configuration overrides.</summary>
public sealed class CaliApiFactory(string environment, IReadOnlyDictionary<string, string?> settings) : WebApplicationFactory<Program>
{
    public CapturingLoggerProvider Logs { get; } = new();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment(environment);
        builder.ConfigureAppConfiguration((_, configuration) =>
        {
            var defaults = new Dictionary<string, string?>
            {
                ["Migrations:ScriptsPath"] = RepoPaths.DbDirectory,
                ["Migrations:ApplyOnStartup"] = "false",
                // Ignore any developer user-secrets key unless a test supplies one.
                ["Auth:DevTokens:SigningKey"] = "",
            };
            foreach (var (key, value) in settings)
            {
                defaults[key] = value;
            }

            configuration.AddInMemoryCollection(defaults);
        });
        builder.ConfigureLogging(logging =>
        {
            logging.AddProvider(Logs);
            // Capture everything (Trace) for this provider regardless of appsettings levels.
            logging.AddFilter<CapturingLoggerProvider>(null, LogLevel.Trace);
        });
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing)
        {
            Logs.Dispose();
        }
    }
}

public sealed class CapturingLoggerProvider : ILoggerProvider
{
    private readonly ConcurrentQueue<string> _entries = new();

    public IReadOnlyCollection<string> Entries => _entries.ToArray();

    public ILogger CreateLogger(string categoryName) => new CapturingLogger(categoryName, _entries);

    public void Dispose()
    {
    }

    private sealed class CapturingLogger(string category, ConcurrentQueue<string> entries) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            // Include structured values as well as the rendered message.
            var values = state is IEnumerable<KeyValuePair<string, object?>> kvs
                ? string.Join(" ", kvs.Select(kv => $"{kv.Key}={kv.Value}"))
                : string.Empty;
            entries.Enqueue($"{logLevel} {category}: {formatter(state, exception)} {values} {exception}");
        }
    }
}
