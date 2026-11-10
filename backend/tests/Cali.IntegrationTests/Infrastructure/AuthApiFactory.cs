using Cali.Infrastructure.Auth;
using Cali.Tests.Shared;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;

namespace Cali.IntegrationTests.Infrastructure;

/// <summary>
/// Hosts Cali.Api for the Sign in with Apple tests: the required auth settings are filled in (see
/// <see cref="AuthTestConfig"/>) and Apple's key set is a fake the test controls, so nothing touches the network.
/// </summary>
public sealed class AuthApiFactory : WebApplicationFactory<Program>
{
    private readonly string _environment;
    private readonly Dictionary<string, string?> _settings;
    private readonly FakeAppleKeySetProvider _keys;

    internal AuthApiFactory(string environment, IReadOnlyDictionary<string, string?> settings, FakeAppleKeySetProvider keys)
    {
        _environment = environment;
        _keys = keys;
        _settings = AuthTestConfig.With(settings);
    }

    public CapturingLoggerProvider Logs { get; } = new();

    /// <summary>The access token signing key this host was configured with (base64).</summary>
    public string AccessKey => _settings[AuthTestConfig.AccessKeySetting]!;

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment(_environment);
        builder.ConfigureAppConfiguration((_, configuration) =>
        {
            var defaults = new Dictionary<string, string?>
            {
                ["Migrations:ScriptsPath"] = RepoPaths.DbDirectory,
                ["Migrations:ApplyOnStartup"] = "false",
                ["Auth:DevTokens:SigningKey"] = "",
                // Every request in a TestServer comes from the same "IP"; keep the default budget out of the way.
                ["RateLimiting:Auth:PermitLimit"] = "100000",
            };
            foreach (var (key, value) in _settings)
            {
                defaults[key] = value;
            }

            configuration.AddInMemoryCollection(defaults);
        });
        builder.ConfigureTestServices(services =>
        {
            services.RemoveAll<IAppleKeySetProvider>();
            services.AddSingleton<IAppleKeySetProvider>(_keys);
        });
        builder.ConfigureLogging(logging =>
        {
            logging.AddProvider(Logs);
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
