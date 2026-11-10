using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Cali.Api.Endpoints;
using Cali.Application.Identity;
using Cali.Domain.Identity;
using Cali.Tests.Shared;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Routing;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.OpenApi;

namespace Cali.ContractTests;

/// <summary>B4 (BE-005): the auth operations and wire shapes against contracts/openapi.yaml (ADR-071).</summary>
public sealed class AuthContractTests : IClassFixture<OpenApiContractTests.SpecFixture>
{
    private readonly OpenApiDocument _spec;

    public AuthContractTests(OpenApiContractTests.SpecFixture fixture)
    {
        ArgumentNullException.ThrowIfNull(fixture);
        _spec = fixture.Document;
    }

    private IOpenApiSchema Schema(string name) => _spec.Components!.Schemas![name];

    private OpenApiOperation Operation(string path) => _spec.Paths[path]!.Operations![HttpMethod.Post];

    private static JsonSerializerOptions Web => new(JsonSerializerDefaults.Web);

    [Fact]
    public void Both_operations_are_anonymous_and_declare_the_statuses_the_API_returns()
    {
        var apple = Operation("/v1/auth/apple");
        var refresh = Operation("/v1/auth/refresh");

        apple.OperationId.ShouldBe("authenticateWithApple");
        refresh.OperationId.ShouldBe("refreshAuthToken");
        apple.Security.ShouldNotBeNull().ShouldBeEmpty();
        refresh.Security.ShouldNotBeNull().ShouldBeEmpty();
        apple.Responses!.Keys.ShouldBe(["200", "400", "401", "413", "415", "429", "503"], ignoreOrder: true);
        refresh.Responses!.Keys.ShouldBe(["200", "400", "401", "413", "415", "429"], ignoreOrder: true);
        apple.Responses["503"]!.Headers!.Keys.ShouldContain("Retry-After");
    }

    private static WebApplicationFactory<Program> Host() =>
        new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
        {
            builder.UseEnvironment("Production");
            builder.ConfigureAppConfiguration((_, configuration) => configuration.AddInMemoryCollection(AuthTestConfig.With(new Dictionary<string, string?>
            {
                ["ConnectionStrings:Cali"] = "Host=127.0.0.1;Port=1;Database=none;Username=none;Password=none;Timeout=1",
            })));
        });

    [Fact]
    public async Task The_endpoints_are_named_after_the_spec_operation_ids_and_allow_anonymous()
    {
        await using var factory = Host();
        _ = factory.Server;

        var endpoints = factory.Services.GetServices<EndpointDataSource>()
            .SelectMany(s => s.Endpoints).OfType<RouteEndpoint>()
            .Where(e => e.RoutePattern.RawText!.StartsWith("/v1/auth/", StringComparison.Ordinal))
            .ToDictionary(e => e.RoutePattern.RawText!, e => e);

        endpoints.Keys.Order().ShouldBe(["/v1/auth/apple", "/v1/auth/refresh"]);
        endpoints["/v1/auth/apple"].Metadata.GetMetadata<IEndpointNameMetadata>()!.EndpointName.ShouldBe(Operation("/v1/auth/apple").OperationId);
        endpoints["/v1/auth/refresh"].Metadata.GetMetadata<IEndpointNameMetadata>()!.EndpointName.ShouldBe(Operation("/v1/auth/refresh").OperationId);
        endpoints.Values.ShouldAllBe(e => e.Metadata.GetMetadata<IAllowAnonymous>() != null);
    }

    [Fact]
    public void A_session_matches_the_AuthTokens_schema()
    {
        var profile = new UserProfile(Guid.NewGuid(), null, "Asia/Bangkok", new DateTimeOffset(2026, 11, 9, 1, 2, 3, TimeSpan.Zero));
        var session = new AuthSession(new string('a', 120), RefreshTokenSecret.Create(), 900, profile);

        var json = JsonSerializer.SerializeToElement(AuthTokensResponse.From(session), Web);

        SchemaValidator.ShouldMatch(json, Schema("AuthTokens"), "AuthTokens");
    }

    [Fact]
    public void The_response_record_has_exactly_the_AuthTokens_properties()
    {
        var declared = Schema("AuthTokens").Properties!.Keys.Order().ToArray();
        var actual = typeof(AuthTokensResponse).GetProperties().Select(p => JsonNamingPolicy.CamelCase.ConvertName(p.Name)).Order().ToArray();

        actual.ShouldBe(declared);
        Schema("AuthTokens").Required!.Order().ShouldBe(declared);
    }

    [Fact]
    public void The_request_limits_in_the_spec_are_the_ones_the_endpoints_enforce()
    {
        var apple = Schema("AppleAuthRequest");
        apple.Required!.ShouldBe(["identityToken", "nonce"], ignoreOrder: true);
        apple.Properties!["identityToken"].MinLength.ShouldBe(AuthEndpoints.MinTokenLength);
        apple.Properties["identityToken"].MaxLength.ShouldBe(AuthEndpoints.MaxIdentityTokenLength);
        apple.Properties["nonce"].MinLength.ShouldBe(AuthEndpoints.MinNonceLength);
        apple.Properties["nonce"].MaxLength.ShouldBe(AuthEndpoints.MaxNonceLength);

        var refresh = Schema("RefreshTokenRequest");
        refresh.Required!.ShouldBe(["refreshToken"]);
        refresh.Properties!["refreshToken"].MinLength.ShouldBe(AuthEndpoints.MinTokenLength);
        refresh.Properties["refreshToken"].MaxLength.ShouldBe(AuthEndpoints.MaxRefreshTokenLength);
        // A token the server issues (43 characters) fits the declared range.
        RefreshTokenSecret.EncodedLength.ShouldBeInRange(AuthEndpoints.MinTokenLength, AuthEndpoints.MaxRefreshTokenLength);
    }

    [Fact]
    public async Task Refusals_from_the_running_API_match_the_Problem_schema()
    {
        // Production, no database: every response below is produced before any database access.
        await using var factory = Host();
        using var client = factory.CreateClient();
        var apple = new Uri("/v1/auth/apple", UriKind.Relative);
        var refresh = new Uri("/v1/auth/refresh", UriKind.Relative);

        using var plain = new StringContent("{}", Encoding.UTF8, "text/plain");
        var cases = new (string Name, HttpResponseMessage Response, HttpStatusCode Expected)[]
        {
            ("apple 400", await client.PostAsJsonAsync(apple, new { nonce = "short" }), HttpStatusCode.BadRequest),
            ("apple 401", await client.PostAsJsonAsync(apple, new { identityToken = "this-is-not-a-jwt", nonce = "nonce-0000001" }), HttpStatusCode.Unauthorized),
            ("apple 415", await client.PostAsync(apple, plain), HttpStatusCode.UnsupportedMediaType),
            ("refresh 400", await client.PostAsJsonAsync(refresh, new { }), HttpStatusCode.BadRequest),
            ("refresh 401", await client.PostAsJsonAsync(refresh, new { refreshToken = "not-a-refresh-token" }), HttpStatusCode.Unauthorized),
        };

        foreach (var (name, response, expected) in cases)
        {
            response.StatusCode.ShouldBe(expected, name);
            response.Content.Headers.ContentType?.MediaType.ShouldBe("application/problem+json", name);
            response.Headers.CacheControl?.NoStore.ShouldBeTrue(name);
            using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            SchemaValidator.ShouldMatch(body.RootElement, Schema("Problem"), $"{name} Problem");
            response.Dispose();
        }
    }
}
