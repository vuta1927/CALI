using System.Security.Cryptography;
using Cali.Api.Auth;
using Cali.Infrastructure.Auth;
using Cali.Tests.Shared;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging.Abstractions;

namespace Cali.UnitTests.Auth;

/// <summary>B4 (BE-005): configuration of the access token key, Apple client id and session lifetimes (ADR-071).</summary>
public sealed class AuthSessionSetupTests
{
    // Later entries win, so a test can override one of the required settings.
    private static IConfiguration Config(params (string Key, string? Value)[] values)
    {
        var map = new Dictionary<string, string?>();
        foreach (var (key, value) in values)
        {
            map[key] = value;
        }

        return new ConfigurationBuilder().AddInMemoryCollection(map).Build();
    }

    private static IConfiguration Required(params (string Key, string? Value)[] extra) =>
        Config([
            (AuthSessionSetup.AccessTokenKeyConfigKey, AuthTestConfig.NewAccessKey()),
            (AuthSessionSetup.AppleClientIdConfigKey, AppleTestTokens.ClientId),
            .. extra,
        ]);

    private static TestEnvironment Env(string name) => new(name);

    [Fact]
    public void Defaults_apply_outside_Development_when_the_required_settings_are_present()
    {
        var settings = AuthSessionSetup.Resolve(Required(), Env(Environments.Production), NullLogger.Instance);

        settings.AccessLifetime.ShouldBe(TimeSpan.FromMinutes(15));
        settings.RefreshLifetime.ShouldBe(TimeSpan.FromDays(60));
        settings.FamilyLifetime.ShouldBe(TimeSpan.FromDays(180));
        settings.AppleClientId.ShouldBe(AppleTestTokens.ClientId);
        settings.AppleKeysUrl.ShouldBe(AppleKeySetOptions.DefaultUrl);
        settings.Audience.ShouldBe(DevTokenDefaults.Audience);
        settings.AccessTokenKey.Length.ShouldBe(32);
    }

    [Fact]
    public void Configured_values_override_the_defaults()
    {
        var settings = AuthSessionSetup.Resolve(
            Required(
                (AuthSessionSetup.AccessTokenMinutesConfigKey, "5"),
                (AuthSessionSetup.RefreshTokenDaysConfigKey, "7"),
                (AuthSessionSetup.RefreshFamilyMaxDaysConfigKey, "30"),
                (AuthSessionSetup.AppleKeysUrlConfigKey, "https://keys.example.test/jwks"),
                (AuthenticationSetup.AudienceConfigKey, "my-api")),
            Env(Environments.Production),
            NullLogger.Instance);

        settings.AccessLifetime.ShouldBe(TimeSpan.FromMinutes(5));
        settings.RefreshLifetime.ShouldBe(TimeSpan.FromDays(7));
        settings.FamilyLifetime.ShouldBe(TimeSpan.FromDays(30));
        settings.AppleKeysUrl.ShouldBe(new Uri("https://keys.example.test/jwks"));
        settings.Audience.ShouldBe("my-api");
    }

    [Theory]
    [InlineData("Production")]
    [InlineData("Staging")]
    public void Outside_Development_the_key_is_required(string environment)
    {
        var configuration = Config((AuthSessionSetup.AppleClientIdConfigKey, AppleTestTokens.ClientId));

        Should.Throw<InvalidOperationException>(() => AuthSessionSetup.Resolve(configuration, Env(environment), NullLogger.Instance))
            .Message.ShouldContain(AuthSessionSetup.AccessTokenKeyConfigKey);
        // A dev token key is not a substitute.
        var withDevKey = Config(
            (AuthSessionSetup.AppleClientIdConfigKey, AppleTestTokens.ClientId),
            (DevTokenDefaults.SigningKeyConfigKey, DevSigningKey.Generate()));
        Should.Throw<InvalidOperationException>(() => AuthSessionSetup.Resolve(withDevKey, Env(environment), NullLogger.Instance));
    }

    [Theory]
    [InlineData("not base64 !!")]
    [InlineData("c2hvcnQ=")] // "short"
    public void An_invalid_key_is_refused_in_every_environment_and_never_echoed(string value)
    {
        foreach (var environment in new[] { Environments.Development, Environments.Production })
        {
            var configuration = Required((AuthSessionSetup.AccessTokenKeyConfigKey, value));

            var error = Should.Throw<InvalidOperationException>(() => AuthSessionSetup.Resolve(configuration, Env(environment), NullLogger.Instance));

            error.Message.ShouldNotContain(value);
            error.Message.ShouldContain(AuthSessionSetup.AccessTokenKeyConfigKey);
        }
    }

    [Fact]
    public void Outside_Development_the_apple_client_id_is_required()
    {
        var configuration = Config((AuthSessionSetup.AccessTokenKeyConfigKey, AuthTestConfig.NewAccessKey()));

        Should.Throw<InvalidOperationException>(() => AuthSessionSetup.Resolve(configuration, Env(Environments.Production), NullLogger.Instance))
            .Message.ShouldContain(AuthSessionSetup.AppleClientIdConfigKey);
    }

    [Fact]
    public void In_Development_a_missing_client_id_disables_apple_sign_in_instead_of_failing()
    {
        var configuration = Config((AuthSessionSetup.AccessTokenKeyConfigKey, AuthTestConfig.NewAccessKey()));

        AuthSessionSetup.Resolve(configuration, Env(Environments.Development), NullLogger.Instance).AppleClientId.ShouldBeNull();
    }

    [Fact]
    public void In_Development_the_key_is_derived_from_the_dev_token_key_and_is_a_different_key()
    {
        var devKey = DevSigningKey.Generate();
        var configuration = Config((DevTokenDefaults.SigningKeyConfigKey, devKey));

        var first = AuthSessionSetup.ResolveKey(configuration, Env(Environments.Development), NullLogger.Instance);
        var second = AuthSessionSetup.ResolveKey(configuration, Env(Environments.Development), NullLogger.Instance);

        first.ShouldBe(second);
        first.Length.ShouldBe(32);
        first.ShouldNotBe(Convert.FromBase64String(devKey));
        // The Sync cursor key is derived from the same secret under another label, so the two never coincide.
        first.ShouldNotBe(HMACSHA256.HashData(Convert.FromBase64String(devKey), "cali.sync.cursor.v1"u8.ToArray()));
    }

    [Fact]
    public void In_Development_without_any_key_a_random_per_process_key_is_used()
    {
        var one = AuthSessionSetup.ResolveKey(Config(), Env(Environments.Development), NullLogger.Instance);
        var two = AuthSessionSetup.ResolveKey(Config(), Env(Environments.Development), NullLogger.Instance);

        one.Length.ShouldBe(32);
        one.ShouldNotBe(two);
    }

    [Theory]
    [InlineData(AuthSessionSetup.AccessTokenMinutesConfigKey, "0")]
    [InlineData(AuthSessionSetup.AccessTokenMinutesConfigKey, "61")]
    [InlineData(AuthSessionSetup.AccessTokenMinutesConfigKey, "fifteen")]
    [InlineData(AuthSessionSetup.AccessTokenMinutesConfigKey, "-5")]
    [InlineData(AuthSessionSetup.AccessTokenMinutesConfigKey, "1.5")]
    [InlineData(AuthSessionSetup.RefreshTokenDaysConfigKey, "0")]
    [InlineData(AuthSessionSetup.RefreshTokenDaysConfigKey, "366")]
    [InlineData(AuthSessionSetup.RefreshFamilyMaxDaysConfigKey, "0")]
    [InlineData(AuthSessionSetup.RefreshFamilyMaxDaysConfigKey, "731")]
    public void Lifetimes_outside_their_bounds_or_not_whole_numbers_are_refused(string key, string value)
    {
        Should.Throw<InvalidOperationException>(() =>
            AuthSessionSetup.Resolve(Required((key, value)), Env(Environments.Production), NullLogger.Instance)).Message.ShouldContain(key);
    }

    [Fact]
    public void The_family_cap_cannot_be_shorter_than_one_refresh_token()
    {
        Should.Throw<InvalidOperationException>(() => AuthSessionSetup.Resolve(
            Required((AuthSessionSetup.RefreshTokenDaysConfigKey, "90"), (AuthSessionSetup.RefreshFamilyMaxDaysConfigKey, "30")),
            Env(Environments.Production),
            NullLogger.Instance));
    }

    [Theory]
    [InlineData("http://keys.example.test/jwks")]
    [InlineData("/relative")]
    [InlineData("ftp://keys.example.test/jwks")]
    public void The_apple_key_url_must_be_an_absolute_https_url(string url)
    {
        Should.Throw<InvalidOperationException>(() => AuthSessionSetup.Resolve(
            Required((AuthSessionSetup.AppleKeysUrlConfigKey, url)), Env(Environments.Production), NullLogger.Instance));
    }

    [Fact]
    public void The_access_token_issuer_is_trusted_in_every_environment_when_settings_are_given_and_never_otherwise()
    {
        var settings = AuthSessionSetup.Resolve(Required(), Env(Environments.Production), NullLogger.Instance);

        foreach (var environment in new[] { Environments.Development, Environments.Production, Environments.Staging })
        {
            TrustedIssuers.Build(Config(), Env(environment), NullLogger.Instance, settings)
                .Select(i => i.Issuer).ShouldContain(AccessTokenDefaults.Issuer);
        }

        TrustedIssuers.Build(Config(), Env(Environments.Production), NullLogger.Instance).ShouldBeEmpty();
    }

    [Fact]
    public void Dev_tokens_stay_Development_only_even_when_the_access_token_issuer_is_registered()
    {
        var settings = AuthSessionSetup.Resolve(Required(), Env(Environments.Production), NullLogger.Instance);
        var configuration = Config((DevTokenDefaults.SigningKeyConfigKey, DevSigningKey.Generate()));

        TrustedIssuers.Build(configuration, Env(Environments.Production), NullLogger.Instance, settings)
            .Select(i => i.Issuer).ShouldBe([AccessTokenDefaults.Issuer]);
        TrustedIssuers.Build(configuration, Env(Environments.Development), NullLogger.Instance, settings)
            .Select(i => i.Issuer).ShouldBe([DevTokenDefaults.Issuer, AccessTokenDefaults.Issuer]);
    }

    private sealed class TestEnvironment(string name) : IHostEnvironment
    {
        public string EnvironmentName { get; set; } = name;
        public string ApplicationName { get; set; } = "Cali.Api";
        public string ContentRootPath { get; set; } = AppContext.BaseDirectory;
        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
    }
}
