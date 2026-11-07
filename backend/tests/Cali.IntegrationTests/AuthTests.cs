using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Cali.Infrastructure.Auth;
using Cali.IntegrationTests.Infrastructure;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Npgsql;

namespace Cali.IntegrationTests;

[Collection(PostgresCollection.Name)]
public sealed class AuthTests(PostgresFixture postgres)
{
    private static readonly Uri Me = new("/v1/me", UriKind.Relative);

    private static byte[] Key(string base64)
    {
        DevSigningKey.TryParse(base64, out var key, out _).ShouldBeTrue();
        return key;
    }

    private static string Mint(string signingKey, Guid sub, TimeSpan? lifetime = null, DateTimeOffset? now = null) =>
        DevTokenFactory.Create(sub, lifetime ?? TimeSpan.FromHours(1), now ?? DateTimeOffset.UtcNow, Key(signingKey));

    private async Task<(string ConnectionString, string SigningKey)> SetupAsync(string prefix)
    {
        var connectionString = await postgres.CreateMigratedDatabaseAsync(prefix);
        return (connectionString, DevSigningKey.Generate());
    }

    private static CaliApiFactory Factory(string environment, string connectionString, string signingKey) =>
        new(environment, new Dictionary<string, string?>
        {
            ["ConnectionStrings:Cali"] = connectionString,
            ["Auth:DevTokens:SigningKey"] = signingKey,
        });

    private static async Task ProvisionUserAsync(string connectionString, Guid id, string? displayName = null)
    {
        await using var dataSource = NpgsqlDataSource.Create(connectionString);
        await using var command = dataSource.CreateCommand("INSERT INTO users (id, display_name) VALUES ($1, $2)");
        command.Parameters.AddWithValue(id);
        command.Parameters.AddWithValue((object?)displayName ?? DBNull.Value);
        await command.ExecuteNonQueryAsync();
    }

    private static async Task<JsonElement> ReadProblemAsync(HttpResponseMessage response, int expectedStatus, string expectedCode)
    {
        response.Content.Headers.ContentType?.MediaType.ShouldBe("application/problem+json");
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        var root = document.RootElement.Clone();
        root.GetProperty("status").GetInt32().ShouldBe(expectedStatus);
        root.GetProperty("code").GetString().ShouldBe(expectedCode);
        root.GetProperty("type").GetString().ShouldNotBeNullOrWhiteSpace();
        root.GetProperty("title").GetString().ShouldNotBeNullOrWhiteSpace();
        root.GetProperty("traceId").GetString().ShouldNotBeNullOrWhiteSpace();
        return root;
    }

    [Fact]
    public async Task Protected_endpoint_without_token_returns_401_problem_json()
    {
        var (connectionString, signingKey) = await SetupAsync("auth_none");
        await using var factory = Factory("Development", connectionString, signingKey);
        using var client = factory.CreateClient();

        var response = await client.GetAsync(Me);

        response.StatusCode.ShouldBe(HttpStatusCode.Unauthorized);
        response.Headers.WwwAuthenticate.ShouldContain(h => h.Scheme == "Bearer");
        await ReadProblemAsync(response, 401, "unauthorized");
    }

    [Fact]
    public async Task Dev_token_is_accepted_in_Development_and_returns_the_db_profile()
    {
        var (connectionString, signingKey) = await SetupAsync("auth_dev_ok");
        var userId = Guid.NewGuid();
        await ProvisionUserAsync(connectionString, userId, "Integration User");
        await using var factory = Factory("Development", connectionString, signingKey);
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", Mint(signingKey, userId));

        var response = await client.GetAsync(Me);

        response.StatusCode.ShouldBe(HttpStatusCode.OK);
        using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        body.RootElement.GetProperty("id").GetGuid().ShouldBe(userId);
        body.RootElement.GetProperty("displayName").GetString().ShouldBe("Integration User");
        body.RootElement.GetProperty("timezone").GetString().ShouldNotBeNullOrWhiteSpace();
        body.RootElement.GetProperty("createdAt").GetDateTimeOffset().Offset.ShouldBe(TimeSpan.Zero);
    }

    [Fact]
    public async Task Dev_token_for_unknown_user_returns_404_problem()
    {
        var (connectionString, signingKey) = await SetupAsync("auth_dev_missing");
        await using var factory = Factory("Development", connectionString, signingKey);
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", Mint(signingKey, Guid.NewGuid()));

        var response = await client.GetAsync(Me);

        response.StatusCode.ShouldBe(HttpStatusCode.NotFound);
        await ReadProblemAsync(response, 404, "user_not_found");
    }

    [Theory]
    [InlineData("Production")]
    [InlineData("Staging")]
    public async Task Dev_token_is_rejected_outside_Development(string environment)
    {
        var (connectionString, signingKey) = await SetupAsync("auth_dev_prod");
        var userId = Guid.NewGuid();
        await ProvisionUserAsync(connectionString, userId);
        await using var factory = Factory(environment, connectionString, signingKey);
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", Mint(signingKey, userId));

        var response = await client.GetAsync(Me);

        response.StatusCode.ShouldBe(HttpStatusCode.Unauthorized);
        await ReadProblemAsync(response, 401, "invalid_token");
    }

    [Fact]
    public async Task Invalid_tokens_are_rejected_in_Development()
    {
        var (connectionString, signingKey) = await SetupAsync("auth_invalid");
        var userId = Guid.NewGuid();
        await ProvisionUserAsync(connectionString, userId);
        await using var factory = Factory("Development", connectionString, signingKey);
        using var client = factory.CreateClient();

        var tokens = new Dictionary<string, string>
        {
            ["expired"] = Mint(signingKey, userId, TimeSpan.FromMinutes(5), DateTimeOffset.UtcNow.AddHours(-1)),
            ["wrong key"] = Mint(DevSigningKey.Generate(), userId),
            ["non-uuid sub"] = SignedWithSubject(signingKey, "alice"),
            ["empty-guid sub"] = SignedWithSubject(signingKey, Guid.Empty.ToString()),
            ["garbage"] = "not.a.jwt",
        };

        foreach (var (name, token) in tokens)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, Me);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            var response = await client.SendAsync(request);
            response.StatusCode.ShouldBe(HttpStatusCode.Unauthorized, name);
            await ReadProblemAsync(response, 401, "invalid_token");
        }
    }

    [Fact]
    public async Task Tokens_and_request_bodies_never_reach_logs()
    {
        var (connectionString, signingKey) = await SetupAsync("auth_logs");
        var userId = Guid.NewGuid();
        await ProvisionUserAsync(connectionString, userId);
        await using var factory = Factory("Development", connectionString, signingKey);
        using var client = factory.CreateClient();
        var token = Mint(signingKey, userId);
        const string bodyMarker = "BODY-MARKER-7f3a9c";

        using (var ok = new HttpRequestMessage(HttpMethod.Get, Me))
        {
            ok.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            (await client.SendAsync(ok)).StatusCode.ShouldBe(HttpStatusCode.OK);
        }

        using (var bad = new HttpRequestMessage(HttpMethod.Post, Me))
        {
            bad.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token + "tampered");
            bad.Content = new StringContent($"{{\"secret\":\"{bodyMarker}\"}}", Encoding.UTF8, "application/json");
            (await client.SendAsync(bad)).StatusCode.ShouldBe(HttpStatusCode.Unauthorized);
        }

        var logs = factory.Logs.Entries;
        logs.ShouldNotBeEmpty();
        var signature = token[(token.LastIndexOf('.') + 1)..];
        foreach (var entry in logs)
        {
            entry.ShouldNotContain(token);
            entry.ShouldNotContain(signature);
            entry.ShouldNotContain(bodyMarker);
            entry.ShouldNotContain(signingKey);
        }
    }

    /// <summary>Correctly signed dev-issuer token whose <c>sub</c> is not a usable user id.</summary>
    private static string SignedWithSubject(string signingKey, string subject)
    {
        var now = DateTime.UtcNow;
        return new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }.CreateToken(new SecurityTokenDescriptor
        {
            Issuer = DevTokenDefaults.Issuer,
            Audience = DevTokenDefaults.Audience,
            Claims = new Dictionary<string, object> { ["sub"] = subject },
            IssuedAt = now,
            NotBefore = now,
            Expires = now.AddHours(1),
            SigningCredentials = new SigningCredentials(new SymmetricSecurityKey(Key(signingKey)), SecurityAlgorithms.HmacSha256),
        });
    }
}
