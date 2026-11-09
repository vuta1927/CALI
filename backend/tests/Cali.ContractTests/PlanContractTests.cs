using System.Text.Json;
using Cali.Api.Endpoints;
using Cali.Application.Plans;
using Cali.Domain.Plans;
using Microsoft.OpenApi;

namespace Cali.ContractTests;

/// <summary>B1 (BE-001/002): plan wire shapes and operation declarations against contracts/openapi.yaml.</summary>
public sealed class PlanContractTests : IClassFixture<OpenApiContractTests.SpecFixture>
{
    private static readonly JsonSerializerOptions Web = new(JsonSerializerDefaults.Web);
    private readonly OpenApiDocument _spec;

    public PlanContractTests(OpenApiContractTests.SpecFixture fixture)
    {
        ArgumentNullException.ThrowIfNull(fixture);
        _spec = fixture.Document;
    }

    private IOpenApiSchema Schema(string name) => _spec.Components!.Schemas![name];

    private OpenApiOperation Operation(HttpMethod method) => _spec.Paths["/v1/plans"]!.Operations![method];

    private static JsonElement Json(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }

    private static readonly string[] Targets =
    [
        """{"kind":"reps","repMin":5,"repMax":8}""",
        """{"kind":"static_hold","holdSeconds":12}""",
        """{"kind":"duration","durationSeconds":600}""",
        """{"kind":"distance","distanceMeters":5000,"durationSeconds":1800}""",
        """{"kind":"load","reps":5,"loadKg":12.5}""",
    ];

    private static TrainingPlan Plan(string kind = PlanKinds.Weekly, Guid? parent = null) => new(
        Guid.NewGuid(), "Push day", kind,
        kind == PlanKinds.Event ? new DateOnly(2027, 3, 1) : null,
        kind == PlanKinds.Event ? "City 10K" : null,
        "mixed",
        [
            new PlannedWorkout(Guid.NewGuid(), 1, "", 0,
                Targets.Select((t, i) => new PlannedExercise(Guid.NewGuid(), Guid.NewGuid(), i, 3, Json(t), 90)).ToArray()),
        ],
        Revision: parent is null ? 1 : 2,
        Version: 1,
        Status: PlanRevisionStatus.Current,
        ParentPlanId: parent,
        LineageId: Guid.NewGuid(),
        EndedAt: null, EndReason: null, EndNote: null, ArchivedAt: null);

    [Fact]
    public void Created_plan_matches_the_TrainingPlan_schema_for_every_target_kind()
    {
        // The exact serializer settings CreatePlan stores as the replay body.
        var json = JsonSerializer.SerializeToElement(Plan(), Web);

        SchemaValidator.ShouldMatch(json, Schema("TrainingPlan"), "TrainingPlan");
        json.GetProperty("parentPlanId").ValueKind.ShouldBe(JsonValueKind.Null);
    }

    [Fact]
    public void Plan_page_matches_the_PlanPage_schema()
    {
        var page = new PlanPageResponse(
            [Plan(), Plan(PlanKinds.Event, parent: Guid.NewGuid())],
            new PlanCursor(DateTime.UtcNow, Guid.NewGuid()).Encode(),
            HasMore: true);

        var json = JsonSerializer.SerializeToElement(page, Web);

        SchemaValidator.ShouldMatch(json, Schema("PlanPage"), "PlanPage");
        json.GetProperty("items")[1].GetProperty("eventDate").GetString().ShouldBe("2027-03-01");
        json.GetProperty("nextCursor").GetString()!.Length.ShouldBeLessThanOrEqualTo(512);
    }

    [Fact]
    public void Empty_last_page_matches_the_PlanPage_schema()
    {
        var json = JsonSerializer.SerializeToElement(new PlanPageResponse([], null, false), Web);

        SchemaValidator.ShouldMatch(json, Schema("PlanPage"), "PlanPage");
    }

    [Fact]
    public void Create_request_example_matches_the_CreatePlanRequest_schema()
    {
        var request = Json($$"""
            {"id":"{{Guid.NewGuid()}}","title":"Push day","kind":"event","eventDate":"2027-03-01","primaryDiscipline":"running",
             "workouts":[{"id":"{{Guid.NewGuid()}}","weekday":1,"orderIndex":0,
               "exercises":[{"id":"{{Guid.NewGuid()}}","exerciseId":"{{Guid.NewGuid()}}","orderIndex":0,"setCount":1,
                 "target":{"kind":"distance","distanceMeters":5000},"restSeconds":0}]}]}
            """);

        SchemaValidator.ShouldMatch(request, Schema("CreatePlanRequest"), "CreatePlanRequest");
    }

    [Fact]
    public void Plan_operations_require_a_bearer_token_and_declare_their_errors()
    {
        var list = Operation(HttpMethod.Get);
        var create = Operation(HttpMethod.Post);

        foreach (var operation in new[] { list, create })
        {
            // No operation-level override: the document-level bearer requirement applies.
            (operation.Security is null || operation.Security.Count > 0).ShouldBeTrue(operation.OperationId);
            operation.Responses!.Keys.ShouldContain("401");
            operation.Responses!.Keys.ShouldContain("429");
        }

        _spec.Security.ShouldNotBeNull().ShouldNotBeEmpty();
        list.Responses!.Keys.ShouldBe(["200", "400", "401", "429"], ignoreOrder: true);
        create.Responses!.Keys.ShouldBe(["201", "400", "401", "404", "409", "413", "415", "429"], ignoreOrder: true);
    }

    [Fact]
    public void Create_requires_a_uuid_idempotency_key_header()
    {
        var header = Operation(HttpMethod.Post).Parameters!.Single(p => p.In == ParameterLocation.Header);

        header.Name.ShouldBe(PlanEndpoints.IdempotencyKeyHeader);
        header.Required.ShouldBeTrue();
        header.Schema!.Format.ShouldBe("uuid");
    }

    [Fact]
    public void List_limit_bounds_match_the_server()
    {
        var limit = Operation(HttpMethod.Get).Parameters!.Single(p => p.Name == "limit").Schema!;

        decimal.Parse(limit.Minimum!, System.Globalization.CultureInfo.InvariantCulture).ShouldBe(1m);
        decimal.Parse(limit.Maximum!, System.Globalization.CultureInfo.InvariantCulture).ShouldBe(ListPlans.MaxLimit);
        limit.Default!.GetValue<decimal>().ShouldBe(ListPlans.DefaultLimit);
    }
}
