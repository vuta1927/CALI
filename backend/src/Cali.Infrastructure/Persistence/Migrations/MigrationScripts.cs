namespace Cali.Infrastructure.Persistence.Migrations;

/// <summary>Script selection and location rules for the <c>db/</c> folder.</summary>
public static class MigrationScripts
{
    /// <summary>File-name marker for scripts that must only ever run in Development (e.g. <c>002_dev_catalog_seed.sql</c>).</summary>
    public const string DevelopmentOnlyMarker = "_dev_";

    public static bool IsDevelopmentOnly(string path) =>
        Path.GetFileName(path).Contains(DevelopmentOnlyMarker, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Filter passed to DbUp. Development-only scripts are included solely when
    /// <paramref name="includeDevelopmentScripts"/> is true, which callers derive from
    /// <c>IHostEnvironment.IsDevelopment()</c> — never from configuration.
    /// </summary>
    public static Func<string, bool> Filter(bool includeDevelopmentScripts) =>
        path => path.EndsWith(".sql", StringComparison.OrdinalIgnoreCase)
                && (includeDevelopmentScripts || !IsDevelopmentOnly(path));

    /// <summary>Resolves the scripts directory; throws when it cannot be found.</summary>
    public static string ResolveDirectory(string? configuredPath, string contentRootPath)
    {
        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            var full = Path.GetFullPath(configuredPath, contentRootPath);
            return Directory.Exists(full)
                ? full
                : throw new DirectoryNotFoundException($"Migrations:ScriptsPath '{full}' does not exist.");
        }

        // Local dev / tests: content root is backend/src/Cali.Api (or a test bin dir); the repo root
        // is the first ancestor holding both db/ and backend/.
        for (var dir = new DirectoryInfo(contentRootPath); dir is not null; dir = dir.Parent)
        {
            var db = Path.Combine(dir.FullName, "db");
            if (Directory.Exists(db) && Directory.Exists(Path.Combine(dir.FullName, "backend")))
            {
                return db;
            }
        }

        throw new DirectoryNotFoundException(
            "Could not locate the db/ migrations folder. Set Migrations:ScriptsPath (env Migrations__ScriptsPath).");
    }
}
