using System.Net;
using System.Text.Json;
using Cali.Api.Endpoints;
using Cali.Domain.Identity;
using Cali.Tests.Shared;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.OpenApi;
using Microsoft.OpenApi.Reader;

namespace Cali.ContractTests;

public sealed class OpenApiContractTests : IClassFixture<OpenApiContractTests.SpecFixture>
{
    private readonly OpenApiDocument _spec;

    public OpenApiContractTests(SpecFixture fixture)
    {
        ArgumentNullException.ThrowIfNull(fixture);
        _spec = fixture.Document;
    }

    [Fact]
    public async Task Spec_parses_without_errors()
    {
        var settings = new OpenApiReaderSettings();
        settings.AddYamlReader();

        var result = await OpenApiDocument.LoadAsync(RepoPaths.OpenApiFile, settings);

        result.Diagnostic.ShouldNotBeNull();
        result.Diagnostic.Errors.ShouldBeEmpty(string.Join(Environment.NewLine, result.Diagnostic.Errors.Select(e => $"{e.Pointer}: {e.Message}")));
        result.Document.ShouldNotBeNull();
        result.Document.Paths.Keys.ShouldContain("/v1/me");
        result.Document.Components!.Schemas!.Keys.ShouldContain("Problem");
    }

    [Fact]
    public async Task Problem_response_from_the_api_matches_the_Problem_schema()
    {
        // Production + no database: the 401 is produced by the auth pipeline before any DB access.
        await using var factory = new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
        {
            builder.UseEnvironment("Production");
            builder.ConfigureAppConfiguration((_, configuration) => configuration.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ConnectionStrings:Cali"] = "Host=127.0.0.1;Port=1;Database=none;Username=none;Password=none;Timeout=1",
            }));
        });
        using var client = factory.CreateClient();

        var response = await client.GetAsync(new Uri("/v1/me", UriKind.Relative));

        response.StatusCode.ShouldBe(HttpStatusCode.Unauthorized);
        response.Content.Headers.ContentType?.MediaType.ShouldBe("application/problem+json");
        using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        AssertMatchesSchema(body.RootElement, Schema("Problem"), "Problem");
    }

    [Fact]
    public void Me_401_response_in_spec_references_Problem()
    {
        var operation = _spec.Paths["/v1/me"]!.Operations![HttpMethod.Get];
        operation.Responses!.Keys.ShouldContain("401");
        // The endpoint returns 404 `user_not_found` for a valid token without a users row.
        operation.Responses["404"]!.Content!["application/problem+json"].Schema.ShouldBeOfType<OpenApiSchemaReference>()
            .Reference.Id.ShouldBe("Problem");
        operation.Responses["200"]!.Content!["application/json"].Schema.ShouldBeOfType<OpenApiSchemaReference>()
            .Reference.Id.ShouldBe("UserProfile");
    }

    [Theory]
    [InlineData("Ada")]
    [InlineData(null)]
    public void UserProfile_response_matches_the_UserProfile_schema(string? displayName)
    {
        var profile = new UserProfile(Guid.NewGuid(), displayName, "Asia/Bangkok", new DateTimeOffset(2026, 11, 7, 1, 2, 3, TimeSpan.Zero));
        var json = JsonSerializer.SerializeToElement(UserProfileResponse.From(profile), new JsonSerializerOptions(JsonSerializerDefaults.Web));

        AssertMatchesSchema(json, Schema("UserProfile"), "UserProfile");
    }

    [Fact]
    public async Task Every_versioned_api_route_is_declared_in_the_spec()
    {
        await using var factory = new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
        {
            builder.UseEnvironment("Production");
            builder.ConfigureAppConfiguration((_, configuration) => configuration.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ConnectionStrings:Cali"] = "Host=127.0.0.1;Port=1;Database=none;Username=none;Password=none;Timeout=1",
            }));
        });
        _ = factory.Server; // build the host

        var routes = factory.Services.GetServices<EndpointDataSource>()
            .SelectMany(s => s.Endpoints)
            .OfType<RouteEndpoint>()
            // Route constraints ({id:guid}) are server-side detail; the spec names the bare parameter ({id}).
            .Select(e => (Path: "/" + RouteConstraint.Replace(e.RoutePattern.RawText!.TrimStart('/'), "{$1}"), Methods: e.Metadata.GetMetadata<HttpMethodMetadata>()?.HttpMethods ?? []))
            .ToList();

        routes.ShouldNotBeEmpty();
        foreach (var (path, methods) in routes)
        {
            _spec.Paths.Keys.ShouldContain(path, $"Route {path} is not declared in contracts/openapi.yaml");
            var declared = _spec.Paths[path]!.Operations!.Keys.Select(m => m.Method).ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var method in methods)
            {
                declared.ShouldContain(method, $"{method} {path} is not declared in contracts/openapi.yaml");
            }
        }
    }

    private static readonly System.Text.RegularExpressions.Regex RouteConstraint =
        new(@"\{(\w+):[^}]+\}", System.Text.RegularExpressions.RegexOptions.None, TimeSpan.FromSeconds(1));

    private IOpenApiSchema Schema(string name) => _spec.Components!.Schemas![name];

    // Problem allows extension members (code, traceId); SchemaValidator only rejects unknown members
    // where the spec says additionalProperties: false.
    private static void AssertMatchesSchema(JsonElement value, IOpenApiSchema schema, string path)
    {
        value.ValueKind.ShouldBe(JsonValueKind.Object, path);
        SchemaValidator.ShouldMatch(value, schema, path);
    }

    public sealed class SpecFixture : IAsyncLifetime
    {
        public OpenApiDocument Document { get; private set; } = null!;

        public async Task InitializeAsync()
        {
            var settings = new OpenApiReaderSettings();
            settings.AddYamlReader();
            var result = await OpenApiDocument.LoadAsync(RepoPaths.OpenApiFile, settings);
            Document = result.Document ?? throw new InvalidOperationException("contracts/openapi.yaml did not parse");
        }

        public Task DisposeAsync() => Task.CompletedTask;
    }
}
