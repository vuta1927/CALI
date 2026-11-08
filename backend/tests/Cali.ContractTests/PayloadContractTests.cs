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

    // ---- CON-006 discipline + load ----

    [Fact]
    public void Load_is_an_exercise_type_and_a_measurement_type()
    {
        Enum("ExerciseType").ShouldContain("load");
        Enum("MeasurementType").ShouldBe(["hold", "reps", "load", "distance", "duration"], ignoreOrder: true);
    }

    [Fact]
    public void Bundle_derives_measurement_type_from_exercise_type_for_every_type()
    {
        // ADR-060: measurementType is a total function of exercise type, enforced in the bundle via if/then.
        var map = new Dictionary<string, string>();
        foreach (var rule in _bundle.GetProperty("$defs").GetProperty("item").GetProperty("allOf").EnumerateArray())
        {
            var type = rule.GetProperty("if").GetProperty("properties").GetProperty("type").GetProperty("const").GetString()!;
            var measurement = rule.GetProperty("then").GetProperty("properties").GetProperty("measurementType").GetProperty("const").GetString()!;
            map.Add(type, measurement);
        }

        map.Keys.ShouldBe(Enum("ExerciseType"), ignoreOrder: true);
        map.Values.ToHashSet().ShouldBe(Enum("MeasurementType"), ignoreOrder: true);
        map["load"].ShouldBe("load");
        map["static_hold"].ShouldBe("hold");
        map["interval"].ShouldBe("duration");
    }

    [Fact]
    public void Exercise_discipline_reuses_the_discipline_vocabulary_without_mixed()
    {
        var item = _bundle.GetProperty("$defs").GetProperty("item");
        var bundleDisciplines = item.GetProperty("properties").GetProperty("discipline").GetProperty("enum")
            .EnumerateArray().Select(e => e.GetString()!).ToHashSet();

        bundleDisciplines.ShouldBe(Enum("Discipline"), ignoreOrder: true);
        bundleDisciplines.ShouldNotContain("mixed");
        Enum("PrimaryDiscipline").IsSupersetOf(Enum("Discipline")).ShouldBeTrue();
        item.GetProperty("required").EnumerateArray().Select(e => e.GetString())
            .ShouldContain(name => name == "discipline");
    }

    [Fact]
    public void Exercise_exposes_discipline_derived_measurement_type_and_focus_tags()
    {
        var exercise = Schema("Exercise");

        var properties = exercise.Properties!;
        var required = exercise.Required!;

        properties.Keys.ShouldContain("discipline");
        properties.Keys.ShouldContain("measurementType");
        properties.Keys.ShouldContain("focusTags");
        required.ShouldContain("discipline");
        required.ShouldContain("measurementType");
        required.ShouldNotContain("focusTags");
        properties["measurementType"].ReadOnly.ShouldBeTrue();
        properties["focusTags"].MaxItems.ShouldBe(10);
    }

    [Fact]
    public void Load_target_requires_reps_and_kilograms_in_both_contracts()
    {
        var openApi = Schema("PlannedTarget").OneOf!.Single(o => o.Properties!["kind"].Const == "load");
        openApi.Required!.ShouldBe(["kind", "reps", "loadKg"], ignoreOrder: true);
        openApi.Properties!.Keys.ShouldBe(["kind", "reps", "loadKg"], ignoreOrder: true);
        openApi.Properties["loadKg"].Minimum.ShouldBe("0");
        openApi.Properties["loadKg"].Maximum.ShouldBe("1000");

        var entity = Def("target").GetProperty("oneOf").EnumerateArray()
            .Single(o => o.GetProperty("properties").GetProperty("kind").GetProperty("const").GetString() == "load");
        entity.GetProperty("required").EnumerateArray().Select(e => e.GetString()!)
            .ShouldBe(["kind", "reps", "loadKg"], ignoreOrder: true);
        entity.GetProperty("properties").GetProperty("loadKg").GetProperty("maximum").GetInt32().ShouldBe(1000);
        entity.GetProperty("properties").GetProperty("reps").GetProperty("maximum").GetInt32().ShouldBe(500);
    }

    [Fact]
    public void Set_result_actual_load_is_optional_non_negative_kilograms()
    {
        var actual = Def("set_result_payload").GetProperty("properties").GetProperty("actualLoadKg");

        actual.GetProperty("minimum").GetInt32().ShouldBe(0);
        actual.GetProperty("maximum").GetInt32().ShouldBe(1000);
        // Backward compatible with v1 payloads.
        Def("set_result_payload").GetProperty("required").EnumerateArray().Select(e => e.GetString())
            .ShouldNotContain("actualLoadKg");
    }

    [Fact]
    public void Volume_and_pounds_are_never_part_of_a_payload()
    {
        // ADR-062: volume is derived; ADR-046: kilograms only, lb is display conversion.
        var names = new List<string>();
        CollectPropertyNames(JsonNode.Parse(File.ReadAllText(RepoPaths.EntityPayloadsSchemaFile))!, names);

        names.ShouldNotContain(name => name.Contains("volume", StringComparison.OrdinalIgnoreCase));
        names.ShouldNotContain(name => name.EndsWith("Lb", StringComparison.Ordinal) || name.EndsWith("Lbs", StringComparison.Ordinal));
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
