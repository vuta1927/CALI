using System.Text.Json;
using Cali.Application.Plans;
using Cali.Application.Sync;
using Cali.Domain.Catalog;

namespace Cali.UnitTests.Sync;

/// <summary>B2 (BE-003): push batch parsing, mutation fingerprints, receipts and per-entity preparation (ADR-069).</summary>
public sealed class SyncTests
{
    private static readonly Guid TuckPlanche = Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1");
    private static readonly Guid PullUp = Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2");

    private static readonly SyncLookups Lookups = new(
        new Dictionary<Guid, string> { [TuckPlanche] = "static_hold", [PullUp] = "reps" },
        new Dictionary<int, string>(),
        new Dictionary<string, IndicatorDefinition>());

    private static JsonElement Json(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }

    private static string Envelope(Guid entityId, string payload, string entityType = "body_measurement", string action = "upsert",
        long baseVersion = 0, string changedAt = "2026-11-07T08:00:00Z", Guid? mutationId = null) =>
        $$"""
        {"mutationId":"{{mutationId ?? Guid.NewGuid()}}","entityType":"{{entityType}}","entityId":"{{entityId}}","action":"{{action}}",
         "baseVersion":{{baseVersion}},"clientChangedAt":"{{changedAt}}","payload":{{payload}}}
        """;

    private static string BodyPayload(Guid id, string value = "72.35") =>
        $$"""{"id":"{{id}}","kind":"weight","value":{{value}},"measuredAt":"2026-11-07T06:45:00Z"}""";

    private static SyncMutation Mutation(string envelope)
    {
        var errors = new ValidationErrors();
        var batch = SyncPushRequestParser.Parse(Json($$"""{"deviceId":"{{Guid.NewGuid()}}","mutations":[{{envelope}}]}"""), errors);
        errors.HasErrors.ShouldBeFalse(string.Join("; ", errors.Fields));
        return batch.ShouldNotBeNull().Mutations.Single();
    }

    private static (SyncPushBatch? Batch, ValidationErrors Errors) Parse(string json)
    {
        var errors = new ValidationErrors();
        return (SyncPushRequestParser.Parse(Json(json), errors), errors);
    }

    // ---- batch parsing ------------------------------------------------------------------------------

    [Fact]
    public void Valid_batch_keeps_every_envelope_in_order()
    {
        var device = Guid.NewGuid();
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();

        var (batch, errors) = Parse($$"""
            {"deviceId":"{{device}}","mutations":[{{Envelope(first, BodyPayload(first))}},
              {{Envelope(second, $$"""{"id":"{{second}}","deletedAt":"2026-11-07T08:00:00Z"}""", action: "delete", baseVersion: 3)}}]}
            """);

        errors.HasErrors.ShouldBeFalse();
        batch.ShouldNotBeNull().DeviceId.ShouldBe(device);
        batch.Mutations.Select(m => m.EntityId).ShouldBe([first, second]);
        batch.Mutations[1].Action.ShouldBe(SyncActions.Delete);
        batch.Mutations[1].BaseVersion.ShouldBe(3);
        batch.Mutations[0].ClientChangedAt.ShouldBe(new DateTimeOffset(2026, 11, 7, 8, 0, 0, TimeSpan.Zero));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(SyncPushRequestParser.MaxMutations + 1)]
    public void Mutation_count_outside_one_to_one_hundred_fails_the_batch(int count)
    {
        var envelopes = string.Join(",", Enumerable.Range(0, count).Select(_ => Guid.NewGuid()).Select(id => Envelope(id, BodyPayload(id))));

        var (batch, errors) = Parse($$"""{"deviceId":"{{Guid.NewGuid()}}","mutations":[{{envelopes}}]}""");

        batch.ShouldBeNull();
        errors.Fields.ShouldBe(["mutations"]);
    }

    [Fact]
    public void One_hundred_mutations_is_accepted()
    {
        var envelopes = string.Join(",", Enumerable.Range(0, SyncPushRequestParser.MaxMutations).Select(_ => Guid.NewGuid()).Select(id => Envelope(id, BodyPayload(id))));

        Parse($$"""{"deviceId":"{{Guid.NewGuid()}}","mutations":[{{envelopes}}]}""").Batch.ShouldNotBeNull().Mutations.Count.ShouldBe(100);
    }

    [Theory]
    [InlineData("""{"mutations":[]}""", "deviceId")]
    [InlineData("""{"deviceId":"not-a-uuid","mutations":[]}""", "deviceId")]
    [InlineData("""[]""", "$")]
    public void Root_errors_fail_the_batch(string json, string field)
    {
        var (batch, errors) = Parse(json);

        batch.ShouldBeNull();
        errors.Fields.ShouldContain(field);
    }

    [Fact]
    public void Unknown_root_property_fails_the_batch()
    {
        var id = Guid.NewGuid();
        var (batch, errors) = Parse($$"""{"deviceId":"{{Guid.NewGuid()}}","mutations":[{{Envelope(id, BodyPayload(id))}}],"extra":1}""");

        batch.ShouldBeNull();
        errors.Fields.ShouldContain("extra");
    }

    [Theory]
    [InlineData("baseVersion", "-1")]
    [InlineData("baseVersion", "1.5")]
    [InlineData("action", "\"patch\"")]
    [InlineData("entityType", "\"\"")]
    [InlineData("clientChangedAt", "\"yesterday\"")]
    [InlineData("payload", "[]")]
    [InlineData("mutationId", "\"m1\"")]
    public void Envelope_errors_are_reported_by_path_and_fail_the_batch(string property, string value)
    {
        var id = Guid.NewGuid();
        var good = Envelope(id, BodyPayload(id));
        var node = System.Text.Json.Nodes.JsonNode.Parse(good)!.AsObject();
        node[property] = System.Text.Json.Nodes.JsonNode.Parse(value);

        var (batch, errors) = Parse($$"""{"deviceId":"{{Guid.NewGuid()}}","mutations":[{{good}},{{node.ToJsonString()}}]}""");

        batch.ShouldBeNull();
        errors.Fields.ShouldBe([$"mutations[1].{property}"]);
    }

    [Fact]
    public void Unknown_entity_type_passes_the_parser_so_it_can_get_a_receipt()
    {
        var id = Guid.NewGuid();

        Mutation(Envelope(id, "{}", entityType: "ai_analysis")).EntityType.ShouldBe("ai_analysis");
    }

    // ---- fingerprint ----------------------------------------------------------------------------------

    [Fact]
    public void Fingerprint_ignores_client_changed_at_and_key_order()
    {
        var id = Guid.NewGuid();
        var mutationId = Guid.NewGuid();
        var original = Mutation(Envelope(id, BodyPayload(id), mutationId: mutationId));
        var resent = Mutation(Envelope(id, $$"""{"measuredAt":"2026-11-07T06:45:00Z","value":72.350,"kind":"weight","id":"{{id}}"}""",
            changedAt: "2026-11-08T10:00:00Z", mutationId: mutationId));

        resent.Fingerprint().ShouldBe(original.Fingerprint());
    }

    [Theory]
    [InlineData("value")]
    [InlineData("baseVersion")]
    [InlineData("action")]
    public void Fingerprint_changes_with_the_mutation_content(string change)
    {
        var id = Guid.NewGuid();
        var original = Mutation(Envelope(id, BodyPayload(id)));
        var changed = Mutation(change switch
        {
            "value" => Envelope(id, BodyPayload(id, "72.36")),
            "baseVersion" => Envelope(id, BodyPayload(id), baseVersion: 1),
            _ => Envelope(id, BodyPayload(id), action: "delete"),
        });

        changed.Fingerprint().ShouldNotBe(original.Fingerprint());
    }

    // ---- receipts -------------------------------------------------------------------------------------

    public static TheoryData<string, bool> StoredReceipts() => new()
    {
        { "applied", true },
        { ReceiptCodes.VersionConflict, true },
        { ReceiptCodes.ValidationFailed, true },
        { ReceiptCodes.CrossUserReference, true },
        { ReceiptCodes.PinnedGoalLimit, true },
        { ReceiptCodes.DependencyMissing, false },
        { ReceiptCodes.MutationIdReused, false },
        { ReceiptCodes.ForbiddenEntity, false },
    };

    [Theory]
    [MemberData(nameof(StoredReceipts))]
    public void Only_final_outcomes_are_stored_for_replay(string outcome, bool stored)
    {
        var id = Guid.NewGuid();
        var receipt = outcome switch
        {
            "applied" => SyncReceipt.Applied(id, 1),
            ReceiptCodes.VersionConflict => SyncReceipt.VersionConflict(id, 2, "{}"),
            ReceiptCodes.DependencyMissing => SyncReceipt.DependencyMissing(id, "sessionId", "missing"),
            _ => SyncReceipt.Rejected(id, outcome, "no"),
        };

        receipt.IsStored.ShouldBe(stored);
    }

    [Fact]
    public void Receipt_json_round_trips()
    {
        var conflict = SyncReceipt.VersionConflict(Guid.NewGuid(), 4, """{"id":"x","value":1}""");
        var rejected = SyncReceipt.Rejected(Guid.NewGuid(), ReceiptCodes.ValidationFailed, "Must equal entityId.", "id");

        foreach (var receipt in new[] { conflict, rejected, SyncReceipt.Applied(Guid.NewGuid(), 7) })
        {
            var json = receipt.ToJson().ToJsonString();
            var back = SyncReceipt.FromJson(json);

            back.ToJson().ToJsonString().ShouldBe(json);
            (back with { ServerEntityJson = null }).ShouldBe(receipt with { ServerEntityJson = null });
        }

        var wire = Json(rejected.ToJson().ToJsonString());
        wire.GetProperty("serverVersion").ValueKind.ShouldBe(JsonValueKind.Null);
        wire.GetProperty("error").GetProperty("details").GetProperty("field").GetString().ShouldBe("id");
        Json(SyncReceipt.Applied(Guid.NewGuid(), 1).ToJson().ToJsonString()).GetProperty("error").ValueKind.ShouldBe(JsonValueKind.Null);
    }

    [Fact]
    public void Dependency_missing_is_a_retryable_conflict()
    {
        var receipt = SyncReceipt.DependencyMissing(Guid.NewGuid(), "sessionId", "Parent not synced yet.");

        receipt.Status.ShouldBe(ReceiptStatuses.Conflict);
        receipt.Error.ShouldNotBeNull().Retryable.ShouldBeTrue();
        receipt.Error.Field.ShouldBe("sessionId");
    }

    // ---- preparation ----------------------------------------------------------------------------------

    [Fact]
    public void Unknown_entity_type_is_forbidden_with_no_table()
    {
        var prepared = SyncEntitySpecs.Prepare(Mutation(Envelope(Guid.NewGuid(), "{}", entityType: "ai_analysis")), Lookups);

        prepared.Table.ShouldBeNull();
        prepared.Rejection.ShouldNotBeNull().Error!.Code.ShouldBe(ReceiptCodes.ForbiddenEntity);
        prepared.Rejection.Error!.Field.ShouldBe("entityType");
        prepared.Rejection.IsStored.ShouldBeFalse();
    }

    [Fact]
    public void Valid_body_measurement_prepares_columns_without_references()
    {
        var id = Guid.NewGuid();
        var prepared = SyncEntitySpecs.Prepare(Mutation(Envelope(id, BodyPayload(id))), Lookups);

        prepared.Rejection.ShouldBeNull();
        prepared.Table.ShouldBe("body_measurements");
        prepared.ServerCreatedAt.ShouldBeTrue();
        prepared.References.ShouldBeEmpty();
        Json(prepared.ChangeJson).GetProperty("id").GetGuid().ShouldBe(id);
    }

    [Fact]
    public void Payload_id_must_equal_entity_id()
    {
        var prepared = SyncEntitySpecs.Prepare(Mutation(Envelope(Guid.NewGuid(), BodyPayload(Guid.NewGuid()))), Lookups);

        prepared.Rejection.ShouldNotBeNull().Error!.Code.ShouldBe(ReceiptCodes.ValidationFailed);
        prepared.Rejection.Error!.Field.ShouldBe("id");
    }

    [Fact]
    public void Delete_needs_deleted_at_and_nothing_else()
    {
        var id = Guid.NewGuid();

        var missing = SyncEntitySpecs.Prepare(Mutation(Envelope(id, $$"""{"id":"{{id}}"}""", action: "delete", baseVersion: 1)), Lookups);
        missing.Rejection.ShouldNotBeNull().Error!.Field.ShouldBe("deletedAt");

        var extra = SyncEntitySpecs.Prepare(Mutation(Envelope(id,
            $$"""{"id":"{{id}}","deletedAt":"2026-11-07T08:00:00Z","value":1}""", action: "delete", baseVersion: 1)), Lookups);
        extra.Rejection.ShouldNotBeNull().Error!.Field.ShouldBe("value");

        SyncEntitySpecs.Prepare(Mutation(Envelope(id, $$"""{"id":"{{id}}","deletedAt":"2026-11-07T08:00:00Z"}""", action: "delete", baseVersion: 1)), Lookups)
            .Rejection.ShouldBeNull();
    }

    [Fact]
    public void Execution_points_at_its_session_and_checks_the_snapshot_against_the_catalog()
    {
        var id = Guid.NewGuid();
        var session = Guid.NewGuid();
        string Payload(Guid exerciseId, string target) => $$$"""
            {"id":"{{{id}}}","sessionId":"{{{session}}}","exerciseId":"{{{exerciseId}}}","orderIndex":0,
             "prescribedSnapshot":{"target":{{{target}}},"setCount":3,"restSeconds":90,"catalogVersion":1}}
            """;

        var prepared = SyncEntitySpecs.Prepare(Mutation(Envelope(id, Payload(PullUp, """{"kind":"reps","repMin":5,"repMax":8}"""),
            entityType: "exercise_execution")), Lookups);
        prepared.Rejection.ShouldBeNull();
        prepared.References.ShouldContain(new ParentReference("sessionId", "workout_sessions", session));

        var wrongKind = SyncEntitySpecs.Prepare(Mutation(Envelope(id, Payload(PullUp, """{"kind":"static_hold","holdSeconds":12}"""),
            entityType: "exercise_execution")), Lookups);
        wrongKind.Rejection.ShouldNotBeNull().Error!.Code.ShouldBe(ReceiptCodes.ValidationFailed);

        // A retired (unpublished) exercise keeps its history: only the FK guards the catalog row.
        var retired = SyncEntitySpecs.Prepare(Mutation(Envelope(id, Payload(Guid.NewGuid(), """{"kind":"static_hold","holdSeconds":12}"""),
            entityType: "exercise_execution")), Lookups);
        retired.Rejection.ShouldBeNull();
    }

    [Fact]
    public void Lookup_keys_cover_payload_and_snapshot_exercises_criteria_versions_and_goals_but_not_deletes()
    {
        var snapshotExercise = Guid.NewGuid();
        var deletedExercise = Guid.NewGuid();
        var id = Guid.NewGuid();
        var mutations = new[]
        {
            Mutation(Envelope(id, $$$"""{"id":"{{{id}}}","exerciseId":"{{{PullUp}}}","criteriaVersion":2,"prescribedSnapshot":{"exerciseId":"{{{snapshotExercise}}}"}}""",
                entityType: "set_result")),
            Mutation(Envelope(id, $$"""{"id":"{{id}}","exerciseId":"{{deletedExercise}}","deletedAt":"2026-11-07T08:00:00Z"}""", action: "delete", baseVersion: 1)),
        };

        var (exercises, versions, indicators) = SyncEntitySpecs.LookupKeys(mutations);

        exercises.ShouldBe([PullUp, snapshotExercise], ignoreOrder: true);
        versions.ShouldBe([2]);
        indicators.ShouldBeFalse();
        SyncEntitySpecs.LookupKeys([Mutation(Envelope(id, "{}", entityType: "plan_goal"))]).NeedsIndicators.ShouldBeTrue();
    }
}
