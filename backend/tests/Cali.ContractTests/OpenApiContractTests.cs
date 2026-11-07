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
            .Select(e => (Path: "/" + e.RoutePattern.RawText!.TrimStart('/'), Methods: e.Metadata.GetMetadata<HttpMethodMetadata>()?.HttpMethods ?? []))
            .Where(r => !r.Path.StartsWith("/health/", StringComparison.Ordinal)) // ops endpoints; see report
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

    private IOpenApiSchema Schema(string name) => _spec.Components!.Schemas![name];

    private static void AssertMatchesSchema(JsonElement value, IOpenApiSchema schema, string path)
    {
        value.ValueKind.ShouldBe(JsonValueKind.Object, path);
        foreach (var required in schema.Required ?? new HashSet<string>())
        {
            value.TryGetProperty(required, out _).ShouldBeTrue($"{path}.{required} is required by the spec");
        }

        var properties = schema.Properties ?? new Dictionary<string, IOpenApiSchema>();
        foreach (var member in value.EnumerateObject())
        {
            // Problem allows extension members; UserProfile has no additionalProperties=false in the spec either.
            if (!properties.TryGetValue(member.Name, out var propertySchema))
            {
                continue;
            }

            AssertType(member.Value, propertySchema, $"{path}.{member.Name}");
        }
    }

    private static void AssertType(JsonElement value, IOpenApiSchema schema, string path)
    {
        var type = schema.Type ?? throw new InvalidOperationException($"{path} has no declared type in the spec");
        var ok = value.ValueKind switch
        {
            JsonValueKind.Null => type.HasFlag(JsonSchemaType.Null),
            JsonValueKind.String => type.HasFlag(JsonSchemaType.String) && FormatOk(value.GetString()!, schema.Format),
            JsonValueKind.Number => type.HasFlag(JsonSchemaType.Number) || (type.HasFlag(JsonSchemaType.Integer) && value.TryGetInt64(out _)),
            JsonValueKind.True or JsonValueKind.False => type.HasFlag(JsonSchemaType.Boolean),
            JsonValueKind.Object => type.HasFlag(JsonSchemaType.Object),
            JsonValueKind.Array => type.HasFlag(JsonSchemaType.Array),
            _ => false,
        };
        ok.ShouldBeTrue($"{path}: JSON {value.ValueKind} '{value}' does not match spec type {type} (format {schema.Format ?? "-"})");
    }

    private static bool FormatOk(string value, string? format) => format switch
    {
        "uuid" => Guid.TryParseExact(value, "D", out _),
        "date-time" => DateTimeOffset.TryParse(value, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out _) && value.Contains('T', StringComparison.Ordinal),
        _ => true,
    };

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
