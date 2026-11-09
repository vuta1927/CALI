using Cali.Infrastructure.Persistence.Migrations;
using Cali.Tests.Shared;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using Testcontainers.PostgreSql;

namespace Cali.IntegrationTests.Infrastructure;

/// <summary>
/// One PostgreSQL 16 container per test run; each test that needs a blank schema gets its own database.
/// </summary>
public sealed class PostgresFixture : IAsyncLifetime
{
    // Keep in sync with docker-compose.yml.
    public const string Image = "postgres:16.15";

    private readonly PostgreSqlContainer _container = new PostgreSqlBuilder(Image)
        .WithDatabase("cali")
        .WithUsername("cali")
        .WithPassword("cali-test-only")
        .Build();

    public string AdminConnectionString => _container.GetConnectionString();

    public Task InitializeAsync() => _container.StartAsync();

    public Task DisposeAsync() => _container.DisposeAsync().AsTask();

    /// <summary>Creates an empty database and returns its connection string.</summary>
    public async Task<string> CreateBlankDatabaseAsync(string prefix)
    {
        var name = $"{prefix}_{Guid.NewGuid():N}"[..Math.Min(prefix.Length + 33, 63)].ToLowerInvariant();
        await using (var connection = new NpgsqlConnection(AdminConnectionString))
        {
            await connection.OpenAsync();
            await using var command = new NpgsqlCommand($"CREATE DATABASE \"{name}\"", connection);
            await command.ExecuteNonQueryAsync();
        }

        // No pooling: every test database would otherwise keep its own idle pool open, and with one
        // database per test the shared container hits max_connections (53300 "too many clients").
        return new NpgsqlConnectionStringBuilder(AdminConnectionString) { Database = name, Pooling = false }.ConnectionString;
    }

    /// <summary>Blank database with production migrations (no dev seed) applied.</summary>
    public async Task<string> CreateMigratedDatabaseAsync(string prefix)
    {
        var connectionString = await CreateBlankDatabaseAsync(prefix);
        var result = new DatabaseMigrator(NullLogger<DatabaseMigrator>.Instance)
            .Run(connectionString, RepoPaths.DbDirectory, includeDevelopmentScripts: false);
        result.Successful.ShouldBeTrue(result.Error?.ToString());
        return connectionString;
    }

    /// <summary>
    /// Blank database migrated only up to and including <paramref name="lastScript"/>,
    /// so a test can seed data in an older schema and then run the full upgrade path.
    /// </summary>
    public async Task<string> CreateDatabaseMigratedUpToAsync(string prefix, string lastScript, bool includeDevelopmentScripts = false)
    {
        var connectionString = await CreateBlankDatabaseAsync(prefix);
        var staged = Directory.CreateTempSubdirectory("cali-db-staged-");
        try
        {
            foreach (var script in Directory.GetFiles(RepoPaths.DbDirectory, "*.sql")
                         .Where(path => string.CompareOrdinal(Path.GetFileName(path), lastScript) <= 0))
            {
                File.Copy(script, Path.Combine(staged.FullName, Path.GetFileName(script)));
            }

            var result = new DatabaseMigrator(NullLogger<DatabaseMigrator>.Instance)
                .Run(connectionString, staged.FullName, includeDevelopmentScripts);
            result.Successful.ShouldBeTrue(result.Error?.ToString());
            result.AppliedScripts.ShouldContain(lastScript);
        }
        finally
        {
            staged.Delete(recursive: true);
        }

        return connectionString;
    }
}

[CollectionDefinition(Name)]
public sealed class PostgresCollection : ICollectionFixture<PostgresFixture>
{
    // All integration tests share one container and run serially (WebApplicationFactory hosts
    // are resolved through a process-wide DiagnosticListener).
    public const string Name = "postgres";
}
