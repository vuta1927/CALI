using Cali.Api.Media;
using Cali.Application.Catalog;
using Cali.Infrastructure.Media;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting.Internal;
using Microsoft.Extensions.Logging.Abstractions;

namespace Cali.UnitTests.Media;

/// <summary>BE-006 (ADR-072): how object storage is configured, in the style of <c>Sync:CursorSigningKey</c>.</summary>
public sealed class MediaSetupTests
{
    private const string Secret = "unit-test-secret-access-key-value";
    private static readonly DateTimeOffset Issued = new(2026, 11, 9, 12, 0, 0, TimeSpan.Zero);

    private static IConfiguration Config(params (string Key, string? Value)[] values) =>
        new ConfigurationBuilder().AddInMemoryCollection(values.ToDictionary(v => v.Key, v => v.Value)).Build();

    private static HostingEnvironment Env(string name) => new() { EnvironmentName = name };

    private static (string, string?)[] Full(params (string Key, string? Value)[] overrides)
    {
        var values = new Dictionary<string, string?>
        {
            [MediaSetup.EndpointConfigKey] = "https://store.example.com",
            [MediaSetup.BucketConfigKey] = "cali-media",
            [MediaSetup.AccessKeyIdConfigKey] = "AKIATESTKEY",
            [MediaSetup.SecretAccessKeyConfigKey] = Secret,
        };
        foreach (var (key, value) in overrides)
        {
            values[key] = value;
        }

        return values.Select(kv => (kv.Key, kv.Value)).ToArray();
    }

    private static IMediaUrlSigner Resolve(string environment, params (string Key, string? Value)[] values) =>
        MediaSetup.ResolveSigner(Config(values), Env(environment), NullLogger.Instance);

    [Fact]
    public void A_full_configuration_gives_a_signer_with_the_default_lifetime_and_region()
    {
        var signed = Resolve("Production", Full()).Sign("a/b.webp", Issued);

        signed.ShouldNotBeNull();
        signed.Url.Host.ShouldBe("store.example.com");
        signed.Url.AbsolutePath.ShouldBe("/cali-media/a/b.webp");
        signed.Url.Query.ShouldContain("%2Fauto%2Fs3%2Faws4_request");
        signed.ExpiresAt.ShouldBe(Issued.AddSeconds(MediaSetup.DefaultLifetimeSeconds));
    }

    [Fact]
    public void Region_and_lifetime_are_configurable()
    {
        var signed = Resolve("Production", Full((MediaSetup.RegionConfigKey, "eu-west-1"), (MediaSetup.LifetimeConfigKey, "120"))).Sign("a.webp", Issued);

        signed!.Url.Query.ShouldContain("%2Feu-west-1%2Fs3%2Faws4_request");
        signed.ExpiresAt.ShouldBe(Issued.AddSeconds(120));
    }

    [Fact]
    public void Development_without_any_storage_setting_runs_without_urls()
    {
        var signer = Resolve("Development");

        signer.ShouldBeOfType<NoMediaUrlSigner>();
        signer.Sign("a/b.webp", Issued).ShouldBeNull();
    }

    [Theory]
    [InlineData("Production")]
    [InlineData("Staging")]
    public void Outside_development_missing_storage_settings_are_a_configuration_error(string environment)
    {
        var exception = Should.Throw<InvalidOperationException>(() => Resolve(environment));

        exception.Message.ShouldContain(MediaSetup.EndpointConfigKey);
        exception.Message.ShouldContain(MediaSetup.SecretAccessKeyConfigKey);
    }

    [Theory]
    [InlineData(MediaSetup.EndpointConfigKey)]
    [InlineData(MediaSetup.BucketConfigKey)]
    [InlineData(MediaSetup.AccessKeyIdConfigKey)]
    [InlineData(MediaSetup.SecretAccessKeyConfigKey)]
    public void A_partly_configured_store_is_an_error_even_in_development(string missing)
    {
        var exception = Should.Throw<InvalidOperationException>(() => Resolve("Development", Full((missing, null))));

        exception.Message.ShouldContain(missing);
        exception.Message.ShouldNotContain(Secret);
    }

    [Theory]
    [InlineData("http://store.example.com", "Production", false)]
    [InlineData("http://localhost:9000", "Production", false)]
    [InlineData("http://localhost:9000", "Development", true)]
    [InlineData("https://store.example.com", "Production", true)]
    [InlineData("https://store.example.com/bucket", "Production", false)]
    [InlineData("https://store.example.com?x=1", "Production", false)]
    [InlineData("store.example.com", "Production", false)]
    [InlineData("ftp://store.example.com", "Development", false)]
    public void The_endpoint_must_be_an_https_origin_and_http_only_in_development(string endpoint, string environment, bool accepted)
    {
        if (accepted)
        {
            Resolve(environment, Full((MediaSetup.EndpointConfigKey, endpoint))).ShouldBeOfType<S3PresignedUrlSigner>();
        }
        else
        {
            Should.Throw<InvalidOperationException>(() => Resolve(environment, Full((MediaSetup.EndpointConfigKey, endpoint))))
                .Message.ShouldNotContain(Secret);
        }
    }

    [Theory]
    [InlineData(MediaSetup.BucketConfigKey, "UPPER")]
    [InlineData(MediaSetup.BucketConfigKey, "ab")]
    [InlineData(MediaSetup.RegionConfigKey, "Europe West")]
    [InlineData(MediaSetup.LifetimeConfigKey, "59")]
    [InlineData(MediaSetup.LifetimeConfigKey, "3601")]
    [InlineData(MediaSetup.LifetimeConfigKey, "abc")]
    [InlineData(MediaSetup.LifetimeConfigKey, "1.5")]
    [InlineData(MediaSetup.LifetimeConfigKey, "-900")]
    public void Invalid_values_are_a_configuration_error_that_does_not_echo_them(string key, string value)
    {
        Should.Throw<InvalidOperationException>(() => Resolve("Production", Full((key, value))))
            .Message.ShouldNotContain(value, Case.Sensitive);
    }

    [Fact]
    public void The_lifetime_defaults_to_fifteen_minutes()
    {
        MediaSetup.ResolveLifetimeSeconds(Config()).ShouldBe(900);
        MediaSetup.ResolveLifetimeSeconds(Config((MediaSetup.LifetimeConfigKey, "3600"))).ShouldBe(3600);
    }
}
