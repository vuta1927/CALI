namespace Cali.Tests.Shared;

/// <summary>Locates repository-level artefacts (contracts/, db/) from a test's output directory.</summary>
internal static class RepoPaths
{
    private static readonly Lazy<string> Root = new(FindRoot);

    public static string RepoRoot => Root.Value;
    public static string DbDirectory => Path.Combine(RepoRoot, "db");
    public static string OpenApiFile => Path.Combine(RepoRoot, "contracts", "openapi.yaml");
    public static string EntityPayloadsSchemaFile => Path.Combine(RepoRoot, "contracts", "entity-payloads.schema.json");
    public static string CatalogBundleSchemaFile => Path.Combine(RepoRoot, "contracts", "catalog-bundle.schema.json");

    private static string FindRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "contracts", "openapi.yaml"))
                && Directory.Exists(Path.Combine(dir.FullName, "db")))
            {
                return dir.FullName;
            }
        }

        throw new DirectoryNotFoundException($"Repository root not found above {AppContext.BaseDirectory}.");
    }
}
