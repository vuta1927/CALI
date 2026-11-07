namespace Cali.Infrastructure.Persistence.Migrations;

/// <summary>Bound from the <c>Migrations</c> configuration section.</summary>
public sealed class MigrationOptions
{
    public const string SectionName = "Migrations";

    /// <summary>
    /// Directory holding the ordered <c>NNN_*.sql</c> scripts (the repo's <c>db/</c> folder).
    /// Relative paths resolve against the host content root. When empty, the runner walks up
    /// from the content root looking for the repository's <c>db/</c> folder.
    /// </summary>
    public string? ScriptsPath { get; set; }

    /// <summary>
    /// Apply pending migrations when the API starts. Honoured ONLY in the Development environment;
    /// other environments must run <c>dotnet run --project src/Cali.Api -- migrate</c>.
    /// </summary>
    public bool ApplyOnStartup { get; set; }

    /// <summary>DbUp journal table (in schema <c>public</c>).</summary>
    public string JournalTable { get; set; } = "schema_versions";
}
