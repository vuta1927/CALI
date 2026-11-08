using System.Text.Json;
using System.Text.Json.Nodes;
using Cali.Tests.Shared;
using Microsoft.OpenApi;

namespace Cali.ContractTests;

/// <summary>
/// Keeps contracts/openapi.yaml, contracts/entity-payloads.schema.json and contracts/catalog-bundle.schema.json
/// in lockstep for the multi-plan slices (docs/19 §10, AGENTS rule 7).
/// </summary>
public sealed class PayloadContractTests : IClassFixture<OpenApiContractTests.SpecFixture>
{
    private readonly OpenApiDocument _spec;
    private readonly JsonElement _entity;
    private readonly JsonElement _bundle;

    public PayloadContractTests(OpenApiContractTests.SpecFixture fixture)
    {
        ArgumentNullException.ThrowIfNull(fixture);
        _spec = fixture.Document;
        _entity = JsonDocument.Parse(File.ReadAllText(RepoPaths.EntityPayloadsSchemaFile)).RootElement;
        _bundle = JsonDocument.Parse(File.ReadAllText(RepoPaths.CatalogBundleSchemaFile)).RootElement;
    }

    // ---- CON-004 running measurement ----

    [Fact]
    public void Exercise_types_include_running_and_match_target_kinds_everywhere()
    {
        var exerciseTypes = Enum("ExerciseType");
        exerciseTypes.ShouldContain("distance");
        exerciseTypes.ShouldContain("duration");

        var openApiKinds = Schema("PlannedTarget").OneOf!.Select(o => o.Properties!["kind"].Const!).ToHashSet();
        var entityKinds = Def("target").GetProperty("oneOf").EnumerateArray()
            .Select(o => o.GetProperty("properties").GetProperty("kind").GetProperty("const").GetString()!).ToHashSet();
        var bundleTypes = _bundle.GetProperty("$defs").GetProperty("item").GetProperty("properties").GetProperty("type")
            .GetProperty("enum").EnumerateArray().Select(e => e.GetString()!).ToHashSet();

        openApiKinds.ShouldBe(exerciseTypes, ignoreOrder: true);
        entityKinds.ShouldBe(exerciseTypes, ignoreOrder: true);
        bundleTypes.ShouldBe(exerciseTypes, ignoreOrder: true);
    }

    [Fact]
    public void Discipline_and_measurement_type_include_running()
    {
        Enum("Discipline").ShouldContain("running");
        Enum("MeasurementType").ShouldContain("distance");
        Enum("MeasurementType").ShouldContain("duration");
    }

    [Fact]
    public void Distance_target_requires_metres_and_takes_an_optional_target_time()
    {
        var distance = Schema("PlannedTarget").OneOf!.Single(o => o.Properties!["kind"].Const == "distance");

        distance.Required!.ShouldBe(["kind", "distanceMeters"], ignoreOrder: true);
        distance.Properties!.Keys.ShouldBe(["kind", "distanceMeters", "durationSeconds"], ignoreOrder: true);
        distance.Properties["durationSeconds"].Maximum.ShouldBe("86400");
    }

    [Fact]
    public void Set_result_accepts_manual_running_fields_and_rejects_healthkit_for_now()
    {
        var properties = Def("set_result_payload").GetProperty("properties");

        properties.TryGetProperty("distanceMeters", out _).ShouldBeTrue();
        properties.GetProperty("durationSeconds").GetProperty("maximum").GetInt32().ShouldBe(86400);
        // ADR-043: 'healthkit' is reserved and not accepted until the Apple Health slice.
        properties.GetProperty("source").GetProperty("enum").EnumerateArray().Select(e => e.GetString())
            .ShouldBe(["manual"]);
        // Backward compatible with v1 payloads: none of the running fields is required.
        Def("set_result_payload").GetProperty("required").EnumerateArray().Select(e => e.GetString())
            .ShouldNotContain(name => name == "distanceMeters" || name == "durationSeconds" || name == "source");
    }

    [Fact]
    public void Pace_is_derived_and_never_part_of_a_payload()
    {
        var names = new List<string>();
        CollectPropertyNames(JsonNode.Parse(File.ReadAllText(RepoPaths.EntityPayloadsSchemaFile))!, names);

        names.ShouldNotContain(name => name.Contains("pace", StringComparison.OrdinalIgnoreCase));
    }

    // ---- CON-003 plan lineage + activation ----

    [Fact]
    public void Plan_activation_is_a_sync_entity_in_every_contract()
    {
        var syncTypes = Enum("SyncEntityType");
        syncTypes.ShouldContain("plan_activation");

        var mutationTypes = _entity.GetProperty("oneOf").EnumerateArray()
            .Select(r => Def(r.GetProperty("$ref").GetString()!.Split('/')[^1]))
            .SelectMany(d => d.GetProperty("allOf").EnumerateArray())
            .Where(part => part.TryGetProperty("properties", out var p) && p.TryGetProperty("entityType", out _))
            .Select(part => part.GetProperty("properties").GetProperty("entityType").GetProperty("const").GetString()!)
            .ToHashSet();
        mutationTypes.ShouldBe(syncTypes, ignoreOrder: true);
        Enum("ChangeEntityType").IsSupersetOf(syncTypes).ShouldBeTrue();
    }

    [Fact]
    public void Training_plan_status_is_a_revision_status_in_both_contracts()
    {
        // ADR-036; the v1 values active/archived are gone (breaking change ADR-056).
        var openApi = Values(Schema("TrainingPlan").AllOf![1].Properties!["status"]);
        var entity = Def("training_plan_payload").GetProperty("properties").GetProperty("status").GetProperty("enum")
            .EnumerateArray().Select(e => e.GetString()!).ToHashSet();

        openApi.ShouldBe(["current", "superseded"], ignoreOrder: true);
        entity.ShouldBe(openApi, ignoreOrder: true);
        // Every new plan field stays optional on the wire.
        Def("training_plan_payload").GetProperty("required").EnumerateArray().Select(e => e.GetString())
            .ShouldBe(["id", "title", "revision", "status"], ignoreOrder: true);
    }

    [Fact]
    public void Event_plan_requires_an_event_date()
    {
        Enum("PlanKind").ShouldBe(["weekly", "event"], ignoreOrder: true);
        Enum("PrimaryDiscipline").IsSupersetOf(Enum("Discipline")).ShouldBeTrue();
        Enum("PrimaryDiscipline").ShouldContain("mixed");

        var plan = Def("training_plan_payload");
        plan.GetProperty("if").GetProperty("properties").GetProperty("kind").GetProperty("const").GetString()
            .ShouldBe("event");
        plan.GetProperty("then").GetProperty("required").EnumerateArray().Select(e => e.GetString())
            .ShouldContain("eventDate");
    }

    [Fact]
    public void Plan_activation_payload_is_closed_and_matches_openapi()
    {
        var payload = Def("plan_activation_payload");
        var openApi = Schema("PlanActivation");

        payload.GetProperty("additionalProperties").GetBoolean().ShouldBeFalse();
        payload.GetProperty("required").EnumerateArray().Select(e => e.GetString()!)
            .ShouldBe(["id", "planLineageId", "fromDate", "timezone"], ignoreOrder: true);
        // The wire payload is the OpenAPI resource minus the server-owned version.
        payload.GetProperty("properties").EnumerateObject().Select(p => p.Name)
            .ShouldBe(openApi.Properties!.Keys.Where(k => k != "version"), ignoreOrder: true);

        var entityReasons = payload.GetProperty("properties").GetProperty("endReason").GetProperty("enum")
            .EnumerateArray().Where(e => e.ValueKind == JsonValueKind.String).Select(e => e.GetString()!).ToHashSet();
        entityReasons.ShouldBe(["paused", "completed", "stopped", "deleted"], ignoreOrder: true);
        Values(openApi.Properties["endReason"]).ShouldBe(entityReasons, ignoreOrder: true);
    }

    [Fact]
    public void Plan_limits_are_reported_as_mutation_errors()
    {
        var codes = Values(Schema("MutationError").Properties!["code"]);

        codes.ShouldContain("active_plan_limit");
        codes.ShouldContain("plan_count_limit");
    }

    // ---- CON-005 plan goals, phases and indicator definitions ----

    [Fact]
    public void Plan_goal_and_plan_phase_are_sync_entities_in_every_contract()
    {
        var syncTypes = Enum("SyncEntityType");

        syncTypes.ShouldContain("plan_goal");
        syncTypes.ShouldContain("plan_phase");
        Enum("ChangeEntityType").ShouldContain("plan_goal");
        Enum("ChangeEntityType").ShouldContain("plan_phase");
        // Plan_activation_is_a_sync_entity_in_every_contract checks the entity-payloads oneOf equals SyncEntityType.
        Def("plan_goal_mutation").ValueKind.ShouldBe(JsonValueKind.Object);
        Def("plan_phase_mutation").ValueKind.ShouldBe(JsonValueKind.Object);
    }

    [Theory]
    [InlineData("PlanGoal", "plan_goal_payload")]
    [InlineData("PlanPhase", "plan_phase_payload")]
    public void Goal_and_phase_payloads_are_closed_and_match_openapi(string openApiName, string defName)
    {
        var payload = Def(defName);
        var openApi = Schema(openApiName);

        payload.GetProperty("additionalProperties").GetBoolean().ShouldBeFalse();
        // The wire payload is the OpenAPI resource minus the server-owned version.
        payload.GetProperty("properties").EnumerateObject().Select(p => p.Name)
            .ShouldBe(openApi.Properties!.Keys.Where(k => k != "version"), ignoreOrder: true);
        payload.GetProperty("required").EnumerateArray().Select(e => e.GetString()!)
            .ShouldBe(openApi.Required!.Where(k => k != "version"), ignoreOrder: true);
    }

    [Fact]
    public void Goal_status_matches_and_current_is_never_on_the_wire()
    {
        var entity = Def("plan_goal_payload").GetProperty("properties").GetProperty("status").GetProperty("enum")
            .EnumerateArray().Select(e => e.GetString()!).ToHashSet();

        Enum("GoalStatus").ShouldBe(["active", "reached", "achieved", "missed", "archived"], ignoreOrder: true);
        entity.ShouldBe(Enum("GoalStatus"), ignoreOrder: true);
        // docs/18 §6.1: current is computed on the device from saved set results.
        Schema("PlanGoal").Properties!.Keys.ShouldNotContain("current");
        Def("plan_goal_payload").GetProperty("properties").TryGetProperty("current", out _).ShouldBeFalse();
    }

    [Fact]
    public void Achieved_requires_achieved_at_and_open_statuses_forbid_it()
    {
        var rules = Def("plan_goal_payload").GetProperty("allOf").EnumerateArray().ToList();

        var achieved = rules.Single(r => r.GetProperty("if").GetProperty("properties").GetProperty("status")
            .TryGetProperty("const", out var c) && c.GetString() == "achieved");
        achieved.GetProperty("then").GetProperty("required").EnumerateArray().Select(e => e.GetString())
            .ShouldContain("achievedAt");
        achieved.GetProperty("then").GetProperty("properties").GetProperty("achievedAt").GetProperty("type").GetString()
            .ShouldBe("string");

        var open = rules.Single(r => r.GetProperty("if").GetProperty("properties").GetProperty("status")
            .TryGetProperty("enum", out _));
        open.GetProperty("if").GetProperty("properties").GetProperty("status").GetProperty("enum").EnumerateArray()
            .Select(e => e.GetString()!).ShouldBe(["active", "reached", "missed"], ignoreOrder: true);
        open.GetProperty("then").GetProperty("properties").GetProperty("achievedAt").GetProperty("type").GetString()
            .ShouldBe("null");
    }

    [Fact]
    public void Goal_target_is_a_value_or_a_range_in_both_contracts()
    {
        var openApi = Schema("GoalTarget").OneOf!.Select(o => string.Join(',', o.Required!.Order(StringComparer.Ordinal))).ToHashSet();
        var entity = Def("goal_target").GetProperty("oneOf").EnumerateArray()
            .Select(o => string.Join(',', o.GetProperty("required").EnumerateArray().Select(e => e.GetString()!).Order(StringComparer.Ordinal)))
            .ToHashSet();

        openApi.ShouldBe(["value", "max,min"], ignoreOrder: true);
        entity.ShouldBe(openApi, ignoreOrder: true);
    }

    [Fact]
    public void Indicator_definition_is_read_only_and_uses_the_measurement_type_enum()
    {
        Enum("IndicatorKind").ShouldBe(["performance", "adherence", "volume", "milestone", "body"], ignoreOrder: true);
        var definition = Schema("IndicatorDefinition");
        Values(definition.Properties!["aggregation"]).ShouldBe(["max", "sum"], ignoreOrder: true);
        definition.Properties["measurementTypes"].Items!.Enum!.Count.ShouldBe(Schema("MeasurementType").Enum!.Count);
        Schema("IndicatorDefinitionSet").Required!.ShouldBe(["version", "publishedAt", "indicators"], ignoreOrder: true);

        // ADR-058: devices never write indicators, so they are neither a sync entity nor a payload.
        Enum("SyncEntityType").ShouldNotContain(t => t.Contains("indicator", StringComparison.Ordinal));
        _entity.GetProperty("$defs").EnumerateObject().Select(p => p.Name)
            .ShouldNotContain(name => name.Contains("indicator", StringComparison.Ordinal));
    }

    [Fact]
    public void Goal_limits_are_reported_as_mutation_errors()
    {
        var codes = Values(Schema("MutationError").Properties!["code"]);

        codes.ShouldContain("pinned_goal_limit");
        codes.ShouldContain("goal_unlock_cycle");
    }

    private HashSet<string> Enum(string schema) => Values(Schema(schema));

    // Microsoft.OpenApi reads a YAML `null` enum member as a sentinel string; nullable enums keep only real values.
    private static HashSet<string> Values(IOpenApiSchema schema) =>
        schema.Enum!.Where(node => node is not null && node.GetValueKind() == JsonValueKind.String)
            .Select(node => node!.GetValue<string>())
            .Where(value => !value.StartsWith("openapi-json-null-sentinel-value", StringComparison.Ordinal))
            .ToHashSet();

    private IOpenApiSchema Schema(string name) => _spec.Components!.Schemas![name];

    private JsonElement Def(string name) => _entity.GetProperty("$defs").GetProperty(name);

    private static void CollectPropertyNames(JsonNode node, List<string> names)
    {
        switch (node)
        {
            case JsonObject obj:
                if (obj["properties"] is JsonObject properties)
                {
                    names.AddRange(properties.Select(p => p.Key));
                }

                foreach (var child in obj)
                {
                    if (child.Value is not null)
                    {
                        CollectPropertyNames(child.Value, names);
                    }
                }

                break;
            case JsonArray array:
                foreach (var item in array.OfType<JsonNode>())
                {
                    CollectPropertyNames(item, names);
                }

                break;
        }
    }
}
