using System.Globalization;
using Cali.Application.VoicePublishing;
using Cali.Infrastructure.Media;
using Cali.Infrastructure.Persistence;
using Cali.Infrastructure.Tts;
using Microsoft.Extensions.Configuration;
using Npgsql;

// BE-007 (CON-010, ADR-077): renders the voice cue script with vbee.vn and publishes it as a new voice pack.
// Publisher-only: needs a storage credential that can write, unlike the API's read-only one.

const string Usage = """
    Usage (from backend/):
      dotnet run --project tools/Cali.VoicePack -- list-voices [--language vi-VN]
          Print vbee voice codes. Only HN - Ngọc Huyền, SG - Tường Vy, HN - Mai Phương, SG - Lan Trinh and
          SG - Thảo Trinh work with the Realtime API used here.

      dotnet run --project tools/Cali.VoicePack -- render --out <dir> [--script <file>]
          Render every cue to <dir>/<key>.caf to listen first (afplay on macOS). Spends vbee credit;
          uploads nothing and writes no database row.

      dotnet run --project tools/Cali.VoicePack -- publish [--script <file>] [--force]
          Render, upload and publish a new version. Does nothing when the latest pack already has the
          same voice and sentences, unless --force.

    Default script: fixtures/voice_cues.vi-VN.json (searched upward from the current directory).

    Configuration (user-secrets id cali-backend-dev, or environment variables):
      Tts__Vbee__AppId, Tts__Vbee__Token (secret), Tts__Vbee__VoiceCode, optional Tts__Vbee__SampleRate (22050)
      publish also: ConnectionStrings__Cali and Media__Storage__Endpoint/Bucket/AccessKeyId/SecretAccessKey
      (+ optional Media__Storage__Region, default auto) with write access to the bucket.
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
catch (Exception ex) when (ex is VbeeException or HttpRequestException or InvalidOperationException or FormatException
                               or InvalidDataException or VoicePackConflictException or NpgsqlException)
{
    // Messages here never contain credentials: vbee errors carry vbee's code/message, uploads only key + status.
    await Console.Error.WriteLineAsync($"error: {ex.Message}").ConfigureAwait(false);
    return 1;
}

static async Task<int> RunAsync(string[] args)
{
    if (args.Length == 0 || args.Contains("--help") || args.Contains("-h"))
    {
        Console.WriteLine(Usage);
        return args.Length == 0 ? 2 : 0;
    }

    var options = ParseOptions(args.Skip(1).ToArray());
    var configuration = new ConfigurationBuilder()
        .AddUserSecrets<Marker>(optional: true)
        .AddEnvironmentVariables()
        .Build();
    using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };

    switch (args[0])
    {
        case "list-voices":
        {
            var vbee = Vbee(configuration, requireVoice: false);
            var voices = await new VbeeTtsClient(http, vbee).ListVoicesAsync(options.GetValueOrDefault("--language", "vi-VN"), CancellationToken.None).ConfigureAwait(false);
            foreach (var voice in voices.OrderBy(v => v.Name, StringComparer.Ordinal))
            {
                Console.WriteLine($"{voice.Code}\t{voice.Name}\t{voice.Gender}\t{voice.LanguageCode}");
            }

            return 0;
        }

        case "render":
        {
            var outDir = options.TryGetValue("--out", out var o) ? o : throw new ArgumentException("render requires --out <dir>.");
            var script = LoadScript(options);
            var vbee = Vbee(configuration, requireVoice: true);
            var renderer = new VbeeCueRenderer(new VbeeTtsClient(http, vbee), vbee);
            Directory.CreateDirectory(outDir);
            foreach (var line in script.Cues)
            {
                var cue = await renderer.RenderAsync(line.Text, CancellationToken.None).ConfigureAwait(false);
                var path = Path.Combine(outDir, $"{line.Key}.caf");
                await File.WriteAllBytesAsync(path, cue.Caf).ConfigureAwait(false);
                Console.WriteLine(string.Create(CultureInfo.InvariantCulture, $"{path}\t{cue.DurationMs} ms\t{line.Text}"));
            }

            return 0;
        }

        case "publish":
        {
            var script = LoadScript(options);
            var vbee = Vbee(configuration, requireVoice: true);
            var connectionString = configuration.GetConnectionString("Cali");
            if (string.IsNullOrWhiteSpace(connectionString))
            {
                throw new ArgumentException("publish requires ConnectionStrings:Cali (env ConnectionStrings__Cali).");
            }

            await using var dataSource = NpgsqlDataSource.Create(connectionString);
            var publisher = new VoicePackPublisher(
                new VbeeCueRenderer(new VbeeTtsClient(http, vbee), vbee),
                new S3ObjectUploader(http, Storage(configuration), TimeProvider.System),
                new VoicePackReader(dataSource),
                new VoicePackWriter(dataSource),
                TimeProvider.System);
            var result = await publisher.PublishAsync(script, options.ContainsKey("--force"),
                new Progress<string>(Console.WriteLine), CancellationToken.None).ConfigureAwait(false);
            Console.WriteLine(result switch
            {
                PublishResult.Unchanged u => $"unchanged: {script.Locale}.v{u.Version} already has this voice and these sentences (use --force to publish anyway)",
                PublishResult.Published p => $"published {p.Pack.Locale}.v{p.Pack.Version} ({p.Pack.Cues.Count} cues, voice '{p.Pack.Voice}')",
                _ => throw new InvalidOperationException("Unknown result."),
            });
            return 0;
        }

        default:
            throw new ArgumentException($"Unknown command '{args[0]}'.");
    }
}

static Dictionary<string, string> ParseOptions(string[] args)
{
    var options = new Dictionary<string, string>(StringComparer.Ordinal);
    for (var i = 0; i < args.Length; i++)
    {
        switch (args[i])
        {
            case "--force":
                options["--force"] = "true";
                break;
            case "--script" or "--out" or "--language":
                options[args[i]] = ++i < args.Length ? args[i] : throw new ArgumentException($"{args[i - 1]} requires a value.");
                break;
            default:
                throw new ArgumentException($"Unknown argument '{args[i]}'.");
        }
    }

    return options;
}

static VoiceCueScript LoadScript(Dictionary<string, string> options)
{
    var path = options.TryGetValue("--script", out var p) ? p : FindUpward(Path.Combine("fixtures", "voice_cues.vi-VN.json"))
        ?? throw new ArgumentException("fixtures/voice_cues.vi-VN.json not found; pass --script <file>.");
    return VoiceCueScript.Parse(File.ReadAllText(path));
}

static string? FindUpward(string relative)
{
    for (var dir = new DirectoryInfo(Directory.GetCurrentDirectory()); dir is not null; dir = dir.Parent)
    {
        var candidate = Path.Combine(dir.FullName, relative);
        if (File.Exists(candidate))
        {
            return candidate;
        }
    }

    return null;
}

static VbeeOptions Vbee(IConfiguration configuration, bool requireVoice)
{
    var section = configuration.GetSection(VbeeOptions.SectionName);
    string Required(string name) => section[name] is { Length: > 0 } value
        ? value
        : throw new ArgumentException($"Missing configuration {VbeeOptions.SectionName}:{name} (env Tts__Vbee__{name}).");

    var sampleRate = section["SampleRate"] is { Length: > 0 } raw
        ? int.Parse(raw, NumberStyles.None, CultureInfo.InvariantCulture)
        : 22050;
    return new VbeeOptions
    {
        AppId = Required("AppId"),
        Token = Required("Token"),
        VoiceCode = requireVoice ? Required("VoiceCode") : section["VoiceCode"] ?? string.Empty,
        SampleRate = sampleRate,
    };
}

static S3StorageOptions Storage(IConfiguration configuration)
{
    var section = configuration.GetSection("Media:Storage");
    string Required(string name) => section[name] is { Length: > 0 } value
        ? value
        : throw new ArgumentException($"Missing configuration Media:Storage:{name} (env Media__Storage__{name}).");

    return new S3StorageOptions
    {
        Endpoint = new Uri(Required("Endpoint")),
        Bucket = Required("Bucket"),
        Region = section["Region"] is { Length: > 0 } region ? region : "auto",
        AccessKeyId = Required("AccessKeyId"),
        SecretAccessKey = Required("SecretAccessKey"),
        Lifetime = TimeSpan.FromMinutes(5),
    };
}

internal sealed class Marker;
