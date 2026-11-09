using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Cali.Api.Endpoints;
using Cali.Application.Catalog;
using Cali.Domain.Catalog;
using Cali.Tests.Shared;
using Microsoft.OpenApi;

namespace Cali.ContractTests;

/// <summary>B1 (BE-001/002): catalog and criteria-config wire shapes against contracts/openapi.yaml.</summary>
public sealed class CatalogContractTests : IClassFixture<OpenApiContractTests.SpecFixture>
{
    private static readonly JsonSerializerOptions Web = new(JsonSerializerDefaults.Web);
    private readonly OpenApiDocument _spec;

    public CatalogContractTests(OpenApiContractTests.SpecFixture fixture)
    {
        ArgumentNullException.ThrowIfNull(fixture);
        _spec = fixture.Document;
    }

    private IOpenApiSchema Schema(string name) => _spec.Components!.Schemas![name];

    private OpenApiOperation Get(string path) => _spec.Paths[path]!.Operations![HttpMethod.Get];

    private static CatalogExercise Exercise(string type, IReadOnlyList<CatalogMedia>? media = null) => new(
        Guid.NewGuid(), "tuck-planche", "Tuck planche", type, "calisthenics", ["push", "core"],
        ["parallettes"], ["Protract the shoulders"], 3, media ?? []);

    [Fact]
    public void Exercise_page_response_matches_the_ExercisePage_schema()
    {
        var media = new CatalogMedia(Guid.NewGuid(), "thumbnail", 2, "internal/key", "image/webp", new string('a', 64), 2048, null, "CC-BY-4.0", null);
        var page = new ExercisePageResponse(
            [ExerciseResponse.From(Exercise("static_hold", [media])), ExerciseResponse.From(Exercise("reps"))],
            new ExerciseCursor("tuck-planche", Guid.NewGuid()).Encode(),
            HasMore: true);

        var json = JsonSerializer.SerializeToElement(page, Web);

        SchemaValidator.ShouldMatch(json, Schema("ExercisePage"), "ExercisePage");
        json.GetRawText().ShouldNotContain("internal/key");
        json.GetProperty("items")[0].GetProperty("media")[0].GetProperty("url").ValueKind.ShouldBe(JsonValueKind.Null);
    }

    [Fact]
    public void Server_exercise_types_equal_the_spec_enum_and_every_type_derives_a_spec_measurement_type()
    {
        var specTypes = Schema("ExerciseType").Enum!.Select(n => n!.GetValue<string>()).ToArray();
        ExerciseTypes.All.ShouldBe(specTypes, ignoreOrder: true);

        foreach (var type in ExerciseTypes.All)
        {
            var json = JsonSerializer.SerializeToElement(ExerciseResponse.From(Exercise(type)), Web);
            SchemaValidator.ShouldMatch(json, Schema("Exercise"), $"Exercise[{type}]");
        }
    }

    [Fact]
    public void Criteria_config_response_matches_the_schema_and_the_published_fixture()
    {
        var fixture = JsonNode.Parse(File.ReadAllText(Path.Combine(RepoPaths.RepoRoot, "fixtures", "criteria_config.json")))!.AsObject();
        fixture.Remove("_comment");
        var indicators = fixture["indicators"]!;
        var document = new JsonObject
        {
            ["supportedTypes"] = fixture["supportedTypes"]!.DeepClone(),
            ["criteria"] = fixture["criteria"]!.DeepClone(),
        };
        var snapshot = new CriteriaConfigSnapshot(
            new CriteriaConfigVersion(
                fixture["version"]!.GetValue<int>(),
                DateTimeOffset.Parse(fixture["publishedAt"]!.GetValue<string>(), CultureInfo.InvariantCulture),
                document.ToJsonString()),
            new IndicatorDefinitionSet(
                indicators["version"]!.GetValue<int>(),
                DateTimeOffset.Parse(indicators["publishedAt"]!.GetValue<string>(), CultureInfo.InvariantCulture),
                indicators["indicators"].Deserialize<IndicatorDefinition[]>(Web)!));

        var json = JsonSerializer.SerializeToNode(CriteriaConfigResponse.From(snapshot), Web)!.AsObject();

        SchemaValidator.ShouldMatch(JsonSerializer.SerializeToElement(json), Schema("CriteriaConfig"), "CriteriaConfig");
        snapshot.ETag.ShouldBe("\"c1.i6\"");
        // Same content as the fixture the iOS app bundles; timestamps compared as instants (Z vs +00:00).
        json.Select(p => p.Key).ShouldBe(fixture.Select(p => p.Key), ignoreOrder: true);
        JsonNode.DeepEquals(json["supportedTypes"], fixture["supportedTypes"]).ShouldBeTrue();
        JsonNode.DeepEquals(json["criteria"], fixture["criteria"]).ShouldBeTrue();
        JsonNode.DeepEquals(json["indicators"]!["indicators"], indicators["indicators"]).ShouldBeTrue(json["indicators"]!["indicators"]!.ToJsonString());
        json["indicators"]!["version"]!.GetValue<int>().ShouldBe(6);
        DateTimeOffset.Parse(json["publishedAt"]!.GetValue<string>(), CultureInfo.InvariantCulture)
            .ShouldBe(snapshot.Criteria.PublishedAt);
    }

    [Fact]
    public void Schema_validator_rejects_undeclared_members_where_additional_properties_is_false()
    {
        using var document = JsonDocument.Parse("""
            {"version":1,"publishedAt":"2026-11-09T00:00:00Z","supportedTypes":[],"criteria":[],
             "indicators":{"version":1,"publishedAt":"2026-11-09T00:00:00Z","indicators":[]},"extra":true}
            """);
        var errors = new List<string>();

        SchemaValidator.Validate(document.RootElement, Schema("CriteriaConfig"), "CriteriaConfig", errors);

        errors.ShouldContain(e => e.Contains("CriteriaConfig.extra", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("/v1/exercises")]
    [InlineData("/v1/exercises/{id}")]
    [InlineData("/v1/criteria-config")]
    public void Catalog_operations_are_anonymous_and_declare_rate_limiting(string path)
    {
        var operation = Get(path);

        operation.Security.ShouldNotBeNull().ShouldBeEmpty($"{path} must declare security: [] (anonymous)");
        operation.Responses!.Keys.ShouldContain("429");
    }

    [Fact]
    public void Criteria_config_declares_conditional_get_and_error_responses()
    {
        var responses = Get("/v1/criteria-config").Responses!;

        responses.Keys.ShouldBe(["200", "304", "400", "404", "429"], ignoreOrder: true);
        responses["200"]!.Headers!.Keys.ShouldBe(["ETag", "Cache-Control"], ignoreOrder: true);
        responses["304"]!.Headers!.Keys.ShouldContain("ETag");
        responses["404"]!.Content!["application/problem+json"].Schema.ShouldBeOfType<OpenApiSchemaReference>()
            .Reference.Id.ShouldBe("Problem");
        Get("/v1/exercises").Responses!.Keys.ShouldContain("400");
        Get("/v1/exercises/{id}").Responses!.Keys.ShouldContain("404");
    }
}
