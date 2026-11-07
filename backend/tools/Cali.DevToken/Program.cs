using System.Globalization;
using Cali.Infrastructure.Auth;
using Microsoft.Extensions.Configuration;
using Npgsql;

// Development-only JWT minting. Tokens from this tool are accepted ONLY by an API running with
// ASPNETCORE_ENVIRONMENT=Development (ADR-015).

const string Usage = """
    Usage:
      dotnet run --project tools/Cali.DevToken -- new-key
          Print a new random base64 signing key (store it in user-secrets or env, never commit it).

      dotnet run --project tools/Cali.DevToken -- [--sub <uuid>] [--expires <timespan>] [--provision]
          Mint a dev access token. Default sub: new UUID. Default expiry: 8h (max 30d).
          --expires accepts 90m, 8h, 7d or a .NET TimeSpan (e.g. 01:30:00).
          --provision inserts a users row for <sub> (idempotent) using ConnectionStrings:Cali.

    Signing key: configuration key Auth:DevTokens:SigningKey from
      env Auth__DevTokens__SigningKey, or user-secrets (id cali-backend-dev).
    """;

try
{
    return await RunAsync(args).ConfigureAwait(false);
}
catch (ArgumentException ex)
{
    await Console.Error.WriteLineAsync($"error: {ex.Message}\n\n{Usage}").ConfigureAwait(false);
    return 2;
}

static async Task<int> RunAsync(string[] args)
{
    if (args.Contains("--help") || args.Contains("-h"))
    {
        Console.WriteLine(Usage);
        return 0;
    }

    if (args.Length > 0 && args[0] == "new-key")
    {
        Console.WriteLine(DevSigningKey.Generate());
        return 0;
    }

    var subject = Guid.NewGuid();
    var lifetime = DevTokenDefaults.DefaultLifetime;
    var provision = false;

    for (var i = 0; i < args.Length; i++)
    {
        switch (args[i])
        {
            case "--sub":
                if (!Guid.TryParse(Next(args, ref i, "--sub"), out subject) || subject == Guid.Empty)
                {
                    throw new ArgumentException("--sub must be a non-empty UUID.");
                }
                break;
            case "--expires":
                lifetime = ParseLifetime(Next(args, ref i, "--expires"));
                break;
            case "--provision":
                provision = true;
                break;
            default:
                throw new ArgumentException($"Unknown argument '{args[i]}'.");
        }
    }

    var configuration = new ConfigurationBuilder()
        .AddUserSecrets<Marker>(optional: true)
        .AddEnvironmentVariables()
        .Build();

    if (!DevSigningKey.TryParse(configuration[DevTokenDefaults.SigningKeyConfigKey], out var key, out var error))
    {
        await Console.Error.WriteLineAsync($"error: {error} Generate one with `new-key`.").ConfigureAwait(false);
        return 1;
    }

    if (provision)
    {
        var connectionString = configuration.GetConnectionString("Cali");
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            await Console.Error.WriteLineAsync("error: --provision requires ConnectionStrings:Cali (env ConnectionStrings__Cali).").ConfigureAwait(false);
            return 1;
        }

        await using var dataSource = NpgsqlDataSource.Create(connectionString);
        await using var command = dataSource.CreateCommand("INSERT INTO users (id) VALUES ($1) ON CONFLICT (id) DO NOTHING");
        command.Parameters.Add(new NpgsqlParameter { Value = subject });
        var inserted = await command.ExecuteNonQueryAsync().ConfigureAwait(false);
        await Console.Error.WriteLineAsync(inserted == 1 ? $"provisioned user {subject:D}" : $"user {subject:D} already exists").ConfigureAwait(false);
    }

    var token = DevTokenFactory.Create(subject, lifetime, DateTimeOffset.UtcNow, key);
    await Console.Error.WriteLineAsync($"sub={subject:D} expires={DateTimeOffset.UtcNow.Add(lifetime):O}").ConfigureAwait(false);
    // Only the token goes to stdout so it can be captured: TOKEN=$(dotnet run ... )
    Console.WriteLine(token);
    return 0;
}

static string Next(string[] args, ref int i, string name) =>
    ++i < args.Length ? args[i] : throw new ArgumentException($"{name} requires a value.");

static TimeSpan ParseLifetime(string value)
{
    var unit = value[^1];
    if (char.IsLetter(unit) && double.TryParse(value[..^1], NumberStyles.Float, CultureInfo.InvariantCulture, out var amount))
    {
        return unit switch
        {
            'm' => TimeSpan.FromMinutes(amount),
            'h' => TimeSpan.FromHours(amount),
            'd' => TimeSpan.FromDays(amount),
            _ => throw new ArgumentException($"Unknown --expires unit '{unit}'."),
        };
    }

    return TimeSpan.TryParse(value, CultureInfo.InvariantCulture, out var span)
        ? span
        : throw new ArgumentException($"Invalid --expires value '{value}'.");
}

internal sealed class Marker;
