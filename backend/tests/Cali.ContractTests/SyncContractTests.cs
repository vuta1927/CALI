using System.Text.Json;
using System.Text.Json.Nodes;
using Cali.Application.Sync;
using Cali.Tests.Shared;
using Microsoft.OpenApi;

namespace Cali.ContractTests;

/// <summary>B2 (BE-003): sync push wire shapes and operation declaration against contracts/openapi.yaml (ADR-069).</summary>
public sealed class SyncContractTests : IClassFixture<OpenApiContractTests.SpecFixture>
{
    private readonly OpenApiDocument _spec;

    public SyncContractTests(OpenApiContractTests.SpecFixture fixture)
    {
        ArgumentNullException.ThrowIfNull(fixture);
        _spec = fixture.Document;
    }

    private IOpenApiSchema Schema(string name) => _spec.Components!.Schemas![name];

    private OpenApiOperation Push => _spec.Paths["/v1/sync/push"]!.Operations![HttpMethod.Post];

    private static JsonElement Json(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }

    private static JsonElement Fixture(params string[] path)
    {
        var node = JsonNode.Parse(File.ReadAllText(Path.Combine([RepoPaths.RepoRoot, "fixtures", .. path])))!.AsObject();
        node.Remove("_comment");
        return Json(node.ToJsonString());
    }

    public static TheoryData<string> Receipts() => new()
    {
        SyncReceipt.Applied(Guid.NewGuid(), 3).ToJson().ToJsonString(),
        (SyncReceipt.Applied(Guid.NewGuid(), 3) with { Status = ReceiptStatuses.Duplicate }).ToJson().ToJsonString(),
        SyncReceipt.VersionConflict(Guid.NewGuid(), 4, """{"id":"0b8c3c2e-8f0e-4a43-9a43-2d9d7c1d1a11","value":72.35}""").ToJson().ToJsonString(),
        SyncReceipt.DependencyMissing(Guid.NewGuid(), "sessionId", "Parent not synced yet.").ToJson().ToJsonString(),
        SyncReceipt.Rejected(Guid.NewGuid(), ReceiptCodes.ValidationFailed, "Must equal entityId.", "id").ToJson().ToJsonString(),
        SyncReceipt.Rejected(Guid.NewGuid(), ReceiptCodes.ForbiddenEntity, "Not writable.", "entityType").ToJson().ToJsonString(),
        SyncReceipt.Rejected(Guid.NewGuid(), ReceiptCodes.PinnedGoalLimit, "Limit reached.").ToJson().ToJsonString(),
    };

    [Theory]
    [MemberData(nameof(Receipts))]
    public void Every_receipt_shape_matches_the_SyncPushResponse_schema(string receipt)
    {
        var response = new JsonObject { ["results"] = new JsonArray(JsonNode.Parse(receipt)) };

        SchemaValidator.ShouldMatch(Json(response.ToJsonString()), Schema("SyncPushResponse"), "SyncPushResponse");
    }

    [Fact]
    public void Every_receipt_code_is_declared_in_MutationError()
    {
        var declared = Schema("MutationError").Properties!["code"].Enum!.Select(e => e!.GetValue<string>()).ToArray();
        var codes = typeof(ReceiptCodes).GetFields().Where(f => f.IsLiteral).Select(f => (string)f.GetRawConstantValue()!).ToArray();

        codes.ShouldBe(declared, ignoreOrder: true);
    }

    [Fact]
    public void Push_fixtures_match_the_SyncPushRequest_schema()
    {
        var samples = Directory.GetFiles(Path.Combine(RepoPaths.RepoRoot, "fixtures", "samples"), "*_sync_push.sample.json")
            .Select(path => Fixture("samples", Path.GetFileName(path)))
            .Prepend(Fixture("sync_push.json"))
            .ToArray();

        samples.Length.ShouldBeGreaterThan(1);
        foreach (var sample in samples)
        {
            SchemaValidator.ShouldMatch(sample, Schema("SyncPushRequest"), "SyncPushRequest");
        }
    }

    [Fact]
    public void Envelope_entity_type_is_open_so_unknown_types_get_a_forbidden_entity_receipt()
    {
        var entityType = Schema("SyncMutation").Properties!["entityType"];

        entityType.Enum.ShouldBeNull();
        entityType.MinLength.ShouldBe(1);
        entityType.MaxLength.ShouldBe(64);
        Schema("SyncEntityType").Enum!.Select(e => e!.GetValue<string>()).ShouldBe(SyncEntityTypes.All, ignoreOrder: true);
    }

    [Fact]
    public void Push_request_is_closed_and_its_batch_size_matches_the_parser()
    {
        var request = Schema("SyncPushRequest");

        request.AdditionalPropertiesAllowed.ShouldBeFalse();
        request.Properties!["mutations"].MinItems.ShouldBe(1);
        request.Properties["mutations"].MaxItems.ShouldBe(SyncPushRequestParser.MaxMutations);
        Schema("SyncMutation").AdditionalPropertiesAllowed.ShouldBeFalse();
    }

    [Fact]
    public void Push_declares_every_status_the_endpoint_returns()
    {
        Push.Responses!.Keys.ShouldBe(["200", "400", "401", "404", "409", "413", "415", "429"], ignoreOrder: true);
    }
}
