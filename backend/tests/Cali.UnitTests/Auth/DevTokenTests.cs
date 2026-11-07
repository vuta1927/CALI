using Cali.Api.Auth;
using Cali.Infrastructure.Auth;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace Cali.UnitTests.Auth;

public sealed class DevTokenTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 7, 9, 0, 0, TimeSpan.Zero);

    private static byte[] NewKey()
    {
        DevSigningKey.TryParse(DevSigningKey.Generate(), out var key, out _).ShouldBeTrue();
        return key;
    }

    [Fact]
    public void Minted_token_carries_sub_issuer_audience_and_expiry()
    {
        var sub = Guid.NewGuid();
        var token = new JsonWebToken(DevTokenFactory.Create(sub, TimeSpan.FromHours(2), Now, NewKey()));

        token.Subject.ShouldBe(sub.ToString("D"));
        token.Issuer.ShouldBe(DevTokenDefaults.Issuer);
        token.Audiences.ShouldBe([DevTokenDefaults.Audience]);
        token.ValidTo.ShouldBe(Now.AddHours(2).UtcDateTime);
        token.Alg.ShouldBe(SecurityAlgorithms.HmacSha256);
    }

    [Fact]
    public async Task Minted_token_validates_with_same_key_only()
    {
        var key = NewKey();
        var token = DevTokenFactory.Create(Guid.NewGuid(), TimeSpan.FromHours(1), DateTimeOffset.UtcNow, key);
        var handler = new JsonWebTokenHandler();

        TokenValidationParameters Params(byte[] k) => new()
        {
            ValidIssuer = DevTokenDefaults.Issuer,
            ValidAudience = DevTokenDefaults.Audience,
            IssuerSigningKey = new SymmetricSecurityKey(k),
        };

        (await handler.ValidateTokenAsync(token, Params(key))).IsValid.ShouldBeTrue();
        (await handler.ValidateTokenAsync(token, Params(NewKey()))).IsValid.ShouldBeFalse();
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-60)]
    [InlineData(31 * 24 * 60)]
    public void Rejects_out_of_range_lifetime(int minutes)
    {
        Should.Throw<ArgumentOutOfRangeException>(() =>
            DevTokenFactory.Create(Guid.NewGuid(), TimeSpan.FromMinutes(minutes), Now, NewKey()));
    }

    [Fact]
    public void Rejects_empty_subject_and_short_key()
    {
        Should.Throw<ArgumentException>(() => DevTokenFactory.Create(Guid.Empty, TimeSpan.FromHours(1), Now, NewKey()));
        Should.Throw<ArgumentException>(() => DevTokenFactory.Create(Guid.NewGuid(), TimeSpan.FromHours(1), Now, new byte[16]));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not base64 !!")]
    [InlineData("c2hvcnQ=")] // "short" — 5 bytes
    public void Key_parsing_rejects_missing_invalid_or_short_keys(string? value)
    {
        DevSigningKey.TryParse(value, out var key, out var error).ShouldBeFalse();
        key.ShouldBeEmpty();
        error.ShouldNotBeNullOrWhiteSpace();
    }

    [Fact]
    public void Dev_issuer_is_trusted_only_in_Development()
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { [DevTokenDefaults.SigningKeyConfigKey] = DevSigningKey.Generate() })
            .Build();

        TrustedIssuers.Build(configuration, new TestEnvironment(Environments.Development), NullLogger.Instance)
            .Select(i => i.Issuer).ShouldBe([DevTokenDefaults.Issuer]);

        foreach (var environment in new[] { Environments.Production, Environments.Staging, "Test" })
        {
            TrustedIssuers.Build(configuration, new TestEnvironment(environment), NullLogger.Instance).ShouldBeEmpty();
        }
    }

    [Fact]
    public void Dev_issuer_is_not_trusted_in_Development_without_a_valid_key()
    {
        var configuration = new ConfigurationBuilder().Build();
        TrustedIssuers.Build(configuration, new TestEnvironment(Environments.Development), NullLogger.Instance).ShouldBeEmpty();
    }

    private sealed class TestEnvironment(string name) : IHostEnvironment
    {
        public string EnvironmentName { get; set; } = name;
        public string ApplicationName { get; set; } = "Cali.Api";
        public string ContentRootPath { get; set; } = AppContext.BaseDirectory;
        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
    }
}
