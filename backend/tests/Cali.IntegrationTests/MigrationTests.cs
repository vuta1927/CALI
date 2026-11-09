using System.Text.RegularExpressions;
using Cali.Api;
using Cali.Infrastructure.Persistence.Migrations;
using Cali.IntegrationTests.Infrastructure;
using Cali.Tests.Shared;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

namespace Cali.IntegrationTests;

[Collection(PostgresCollection.Name)]
public sealed partial class MigrationTests(PostgresFixture postgres)
{
    private static readonly DatabaseMigrator Migrator = new(NullLogger<DatabaseMigrator>.Instance);

    [GeneratedRegex(@"^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?""?(\w+)""?", RegexOptions.IgnoreCase | RegexOptions.Multiline)]
    private static partial Regex CreateTable();

    private static string[] TablesDeclaredIn001() =>
        CreateTable().Matches(File.ReadAllText(Path.Combine(RepoPaths.DbDirectory, "001_initial.sql")))
            .Select(m => m.Groups[1].Value.ToLowerInvariant())
            .Distinct()
            .ToArray();

    [Fact]
    public async Task Migrations_apply_to_blank_database_and_create_every_table_in_001()
    {
        var connectionString = await postgres.CreateBlankDatabaseAsync("mig_blank");

        var result = Migrator.Run(connectionString, RepoPaths.DbDirectory, includeDevelopmentScripts: false);

        result.Successful.ShouldBeTrue(result.Error?.ToString());
        result.AppliedScripts.ShouldContain("001_initial.sql");
        result.AppliedScripts.ShouldNotContain(s => MigrationScripts.IsDevelopmentOnly(s));
        // Full production upgrade path in order: 001 -> 003 (CON-004) -> 004 (CON-003) ...
        result.AppliedScripts.ShouldBe(AllScripts(includeDevelopment: false));
        result.AppliedScripts.ShouldContain("003_running_measurement.sql");
        result.AppliedScripts.ShouldContain("004_plan_lineage_activation.sql");
        (await PublicTablesAsync(connectionString)).ShouldContain("plan_activations");
        // CON-005
        result.AppliedScripts.ShouldContain("005_plan_goals_phases.sql");
        (await PublicTablesAsync(connectionString)).ShouldContain("plan_goals");
        // CON-007
        result.AppliedScripts.ShouldContain("007_body_measurement.sql");
        (await PublicTablesAsync(connectionString)).ShouldContain("body_measurements");

        var expected = TablesDeclaredIn001();
        expected.Length.ShouldBeGreaterThanOrEqualTo(17);
        var actual = await PublicTablesAsync(connectionString);
        foreach (var table in expected)
        {
            actual.ShouldContain(table);
        }

        (await CountAsync(connectionString, "SELECT count(*) FROM exercise_catalog")).ShouldBe(0);

        // Journaled: a second run applies nothing.
        var rerun = Migrator.Run(connectionString, RepoPaths.DbDirectory, includeDevelopmentScripts: false);
        rerun.Successful.ShouldBeTrue();
        rerun.AppliedScripts.ShouldBeEmpty();
    }

    [Fact]
    public async Task Development_scripts_are_applied_only_when_included()
    {
        var connectionString = await postgres.CreateBlankDatabaseAsync("mig_dev");

        var result = Migrator.Run(connectionString, RepoPaths.DbDirectory, includeDevelopmentScripts: true);

        result.Successful.ShouldBeTrue(result.Error?.ToString());
        result.AppliedScripts.ShouldContain("002_dev_catalog_seed.sql");
        (await CountAsync(connectionString, "SELECT count(*) FROM exercise_catalog")).ShouldBeGreaterThan(0);
    }

    [Fact]
    public async Task Migrate_command_in_Production_applies_schema_without_dev_seed()
    {
        var connectionString = await postgres.CreateBlankDatabaseAsync("mig_cmd");

        var exitCode = CaliApi.RunMigrateCommand(
        [
            "--environment", "Production",
            $"--ConnectionStrings:Cali={connectionString}",
            $"--Migrations:ScriptsPath={RepoPaths.DbDirectory}",
        ]);

        exitCode.ShouldBe(0);
        (await PublicTablesAsync(connectionString)).ShouldContain("users");
        (await JournalAsync(connectionString)).ShouldNotContain("002_dev_catalog_seed.sql");
        (await CountAsync(connectionString, "SELECT count(*) FROM exercise_catalog")).ShouldBe(0);
    }

    [Fact]
    public async Task Api_startup_in_Development_applies_migrations_including_dev_seed()
    {
        var connectionString = await postgres.CreateBlankDatabaseAsync("mig_startup");
        await using var factory = new CaliApiFactory("Development", new Dictionary<string, string?>
        {
            ["ConnectionStrings:Cali"] = connectionString,
            ["Migrations:ApplyOnStartup"] = "true",
        });

        using var client = factory.CreateClient();
        (await client.GetAsync(new Uri("/health/ready", UriKind.Relative))).IsSuccessStatusCode.ShouldBeTrue();

        (await JournalAsync(connectionString)).ShouldBe(AllScripts(includeDevelopment: true));
    }

    [Fact]
    public async Task Api_startup_outside_Development_never_migrates()
    {
        var connectionString = await postgres.CreateBlankDatabaseAsync("mig_prod_startup");
        await using var factory = new CaliApiFactory("Production", new Dictionary<string, string?>
        {
            ["ConnectionStrings:Cali"] = connectionString,
            ["Migrations:ApplyOnStartup"] = "true",
        });

        using var client = factory.CreateClient();
        (await client.GetAsync(new Uri("/health/live", UriKind.Relative))).IsSuccessStatusCode.ShouldBeTrue();

        (await PublicTablesAsync(connectionString)).ShouldBeEmpty();
    }

    /// <summary>Every db/*.sql file in apply order (DbUp sorts by file name), optionally without _dev_ scripts.</summary>
    private static string[] AllScripts(bool includeDevelopment) =>
        Directory.GetFiles(RepoPaths.DbDirectory, "*.sql")
            .Select(Path.GetFileName)
            .OfType<string>()
            .Where(name => includeDevelopment || !MigrationScripts.IsDevelopmentOnly(name))
            .Order(StringComparer.Ordinal)
            .ToArray();

    private static async Task<List<string>> PublicTablesAsync(string connectionString) =>
        await QueryStringsAsync(connectionString,
            "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' AND table_name <> 'schema_versions'");

    private static async Task<List<string>> JournalAsync(string connectionString) =>
        await QueryStringsAsync(connectionString, "SELECT scriptname FROM public.schema_versions ORDER BY schemaversionsid");

    private static async Task<List<string>> QueryStringsAsync(string connectionString, string sql)
    {
        await using var dataSource = NpgsqlDataSource.Create(connectionString);
        await using var command = dataSource.CreateCommand(sql);
        await using var reader = await command.ExecuteReaderAsync();
        var values = new List<string>();
        while (await reader.ReadAsync())
        {
            values.Add(reader.GetString(0));
        }

        return values;
    }

    private static async Task<long> CountAsync(string connectionString, string sql)
    {
        await using var dataSource = NpgsqlDataSource.Create(connectionString);
        await using var command = dataSource.CreateCommand(sql);
        return (long)(await command.ExecuteScalarAsync())!;
    }
}
