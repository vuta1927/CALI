using Cali.Api;

// `dotnet run --project src/Cali.Api -- migrate [--environment X]` applies migrations and exits.
if (args.Length > 0 && string.Equals(args[0], "migrate", StringComparison.OrdinalIgnoreCase))
{
    return CaliApi.RunMigrateCommand(args[1..]);
}

var app = CaliApi.Build(args);
if (!CaliApi.ApplyStartupMigrations(app))
{
    return 1;
}

await app.RunAsync().ConfigureAwait(false);
return 0;

/// <summary>Entry point marker for WebApplicationFactory.</summary>
public partial class Program;
