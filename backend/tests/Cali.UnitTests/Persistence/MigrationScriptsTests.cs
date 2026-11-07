using Cali.Infrastructure.Persistence.Migrations;
using Cali.Tests.Shared;

namespace Cali.UnitTests.Persistence;

public sealed class MigrationScriptsTests
{
    [Theory]
    [InlineData("001_initial.sql", false, true)]
    [InlineData("001_initial.sql", true, true)]
    [InlineData("002_dev_catalog_seed.sql", false, false)]
    [InlineData("002_dev_catalog_seed.sql", true, true)]
    [InlineData("003_DEV_fixtures.sql", false, false)]
    [InlineData("README.md", true, false)]
    public void Filter_includes_dev_scripts_only_when_requested(string file, bool includeDev, bool expected)
    {
        MigrationScripts.Filter(includeDev)(Path.Combine("db", file)).ShouldBe(expected);
    }

    [Fact]
    public void Repo_db_folder_contains_a_dev_only_seed()
    {
        Directory.GetFiles(RepoPaths.DbDirectory, "*.sql").Select(Path.GetFileName)
            .ShouldContain("002_dev_catalog_seed.sql");
        MigrationScripts.IsDevelopmentOnly("002_dev_catalog_seed.sql").ShouldBeTrue();
    }

    [Fact]
    public void Resolves_configured_relative_path_against_content_root()
    {
        var resolved = MigrationScripts.ResolveDirectory("db", RepoPaths.RepoRoot);
        resolved.ShouldBe(RepoPaths.DbDirectory);
    }

    [Fact]
    public void Discovers_repo_db_folder_when_not_configured()
    {
        var contentRoot = Path.Combine(RepoPaths.RepoRoot, "backend", "src", "Cali.Api");
        MigrationScripts.ResolveDirectory(null, contentRoot).ShouldBe(RepoPaths.DbDirectory);
    }

    [Fact]
    public void Throws_for_missing_configured_path()
    {
        Should.Throw<DirectoryNotFoundException>(() =>
            MigrationScripts.ResolveDirectory(Path.Combine(RepoPaths.RepoRoot, "does-not-exist"), RepoPaths.RepoRoot));
    }
}
