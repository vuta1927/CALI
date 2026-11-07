using DbUp;
using DbUp.Engine.Output;
using DbUp.ScriptProviders;
using Microsoft.Extensions.Logging;

namespace Cali.Infrastructure.Persistence.Migrations;

public sealed record MigrationResult(bool Successful, IReadOnlyList<string> AppliedScripts, string? ErrorScript, Exception? Error);

/// <summary>
/// Applies <c>db/*.sql</c> in file-name order with DbUp, journaled in <see cref="MigrationOptions.JournalTable"/>.
/// Each script runs in its own transaction. SQL files in <c>db/</c> are the schema source of truth (ADR-014).
/// </summary>
public sealed class DatabaseMigrator(ILogger<DatabaseMigrator> logger)
{
    public MigrationResult Run(string connectionString, string scriptsDirectory, bool includeDevelopmentScripts, string journalTable = "schema_versions")
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(scriptsDirectory);

        // Never log the connection string (it carries credentials).
        logger.LogInformation(
            "Applying database migrations from {ScriptsDirectory} (development scripts: {IncludeDevelopmentScripts})",
            scriptsDirectory, includeDevelopmentScripts);

        var engine = DeployChanges.To
            .PostgresqlDatabase(connectionString)
            .WithScriptsFromFileSystem(scriptsDirectory, new FileSystemScriptOptions
            {
                Filter = MigrationScripts.Filter(includeDevelopmentScripts),
                IncludeSubDirectories = false,
                UseOnlyFilenameForScriptName = true,
            })
            .WithTransactionPerScript()
            .WithVariablesDisabled()
            .JournalToPostgresqlTable("public", journalTable)
            .LogTo(new UpgradeLogAdapter(logger))
            .Build();

        var result = engine.PerformUpgrade();
        var applied = result.Scripts.Select(s => s.Name).ToArray();

        if (result.Successful)
        {
            logger.LogInformation("Database migrations complete; {AppliedCount} script(s) applied", applied.Length);
            return new MigrationResult(true, applied, null, null);
        }

        logger.LogError(result.Error, "Database migration failed in script {ErrorScript}", result.ErrorScript?.Name);
        return new MigrationResult(false, applied, result.ErrorScript?.Name, result.Error);
    }

    /// <summary>Routes DbUp output into Microsoft.Extensions.Logging without treating DbUp text as a template.</summary>
    private sealed class UpgradeLogAdapter(ILogger logger) : IUpgradeLog
    {
        public void LogTrace(string format, params object[] args) => Write(LogLevel.Trace, null, format, args);
        public void LogDebug(string format, params object[] args) => Write(LogLevel.Debug, null, format, args);
        public void LogInformation(string format, params object[] args) => Write(LogLevel.Information, null, format, args);
        public void LogWarning(string format, params object[] args) => Write(LogLevel.Warning, null, format, args);
        public void LogError(string format, params object[] args) => Write(LogLevel.Error, null, format, args);
        public void LogError(Exception ex, string format, params object[] args) => Write(LogLevel.Error, ex, format, args);

        private void Write(LogLevel level, Exception? ex, string format, object[] args)
        {
            if (!logger.IsEnabled(level))
            {
                return;
            }

            var message = args is { Length: > 0 }
                ? string.Format(System.Globalization.CultureInfo.InvariantCulture, format, args)
                : format;
            logger.Log(level, ex, "DbUp: {DbUpMessage}", message);
        }
    }
}
