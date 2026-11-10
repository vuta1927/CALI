using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Cali.Infrastructure.Auth;
using Cali.IntegrationTests.Infrastructure;
using Cali.Tests.Shared;
using Npgsql;

namespace Cali.IntegrationTests;

/// <summary>
/// B2 (BE-003): POST /v1/sync/push — one transaction per push, idempotent per mutationId, a receipt for
/// every mutation (docs/08, ADR-021, ADR-069). Parents and rule "worlds" are seeded through the endpoint
/// itself so the tests exercise the real write path.
/// </summary>
[Collection(PostgresCollection.Name)]
public sealed class SyncPushTests(PostgresFixture postgres)
{
    private static readonly Uri Push = new("/v1/sync/push", UriKind.Relative);
    private const string SeedAt = "2026-11-07T08:00:00Z";
    private const string TimeZone = "Asia/Ho_Chi_Minh";

    // fixtures/exercise_catalog.json
    private static readonly Guid TuckPlanche = Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1");
    private static readonly Guid PullUp = Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2");

    private sealed record Setup(string ConnectionString, string SigningKey, Guid UserA, Guid UserB);

    private async Task<Setup> SetupAsync(string prefix)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync(prefix);
        var setup = new Setup(cs, DevSigningKey.Generate(), Guid.NewGuid(), Guid.NewGuid());
        await ExecuteAsync(cs, "INSERT INTO users (id) VALUES ($1), ($2)", setup.UserA, setup.UserB);
        using var catalog = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(RepoPaths.RepoRoot, "fixtures", "exercise_catalog.json")));
        foreach (var item in catalog.RootElement.GetProperty("items").EnumerateArray())
        {
            await ExecuteAsync(cs, """
                INSERT INTO exercise_catalog (id, slug, name, exercise_type, discipline, is_published)
                VALUES ($1, $2, $3, $4, $5, true)
                """,
                item.GetProperty("id").GetGuid(), item.GetProperty("slug").GetString(), item.GetProperty("name").GetString(),
                item.GetProperty("type").GetString(), item.GetProperty("discipline").GetString());
        }

        return setup;
    }

    private static CaliApiFactory Factory(Setup setup) =>
        new("Development", new Dictionary<string, string?>
        {
            ["ConnectionStrings:Cali"] = setup.ConnectionString,
            ["Auth:DevTokens:SigningKey"] = setup.SigningKey,
            ["RateLimiting:Sync:PermitLimit"] = "100000",
            ["RateLimiting:Sync:WindowSeconds"] = "60",
        });

    private static HttpClient Client(CaliApiFactory factory, Setup setup, Guid userId)
    {
        DevSigningKey.TryParse(setup.SigningKey, out var key, out _).ShouldBeTrue();
        var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer", DevTokenFactory.Create(userId, TimeSpan.FromHours(1), DateTimeOffset.UtcNow, key));
        return client;
    }

    private static Guid Id(string prefix, int n) =>
        Guid.Parse(string.Create(CultureInfo.InvariantCulture, $"{prefix}000000-0000-4000-8000-{n:D12}"));

    // ---- request builders -------------------------------------------------------------------------

    private static JsonObject Upsert(string entityType, Guid entityId, JsonObject payload, long baseVersion = 0,
        Guid? mutationId = null, string changedAt = SeedAt)
    {
        payload["id"] = entityId.ToString();
        return new JsonObject
        {
            ["mutationId"] = (mutationId ?? Guid.NewGuid()).ToString(),
            ["entityType"] = entityType,
            ["entityId"] = entityId.ToString(),
            ["action"] = "upsert",
            ["baseVersion"] = baseVersion,
            ["clientChangedAt"] = changedAt,
            ["payload"] = payload,
        };
    }

    private static JsonObject Delete(string entityType, Guid entityId, long baseVersion, Guid? mutationId = null) =>
        new()
        {
            ["mutationId"] = (mutationId ?? Guid.NewGuid()).ToString(),
            ["entityType"] = entityType,
            ["entityId"] = entityId.ToString(),
            ["action"] = "delete",
            ["baseVersion"] = baseVersion,
            ["clientChangedAt"] = SeedAt,
            ["payload"] = new JsonObject { ["id"] = entityId.ToString(), ["deletedAt"] = SeedAt },
        };

    private static JsonObject Body(decimal value) =>
        new() { ["kind"] = "weight", ["value"] = value, ["measuredAt"] = "2026-11-07T06:45:00Z" };

    private static JsonObject Plan(string title) =>
        new() { ["title"] = title, ["revision"] = 1, ["status"] = "current", ["kind"] = "weekly", ["primaryDiscipline"] = "calisthenics" };

    private static JsonObject Session() =>
        new()
        {
            ["localDate"] = "2026-11-07", ["timezone"] = TimeZone, ["status"] = "completed", ["phase"] = "completed",
            ["startedAt"] = "2026-11-07T07:00:00Z", ["finishedAt"] = "2026-11-07T07:50:00Z",
        };

    private static JsonObject Execution(Guid sessionId, Guid exerciseId, int orderIndex, JsonObject target) =>
        new()
        {
            ["sessionId"] = sessionId.ToString(), ["exerciseId"] = exerciseId.ToString(), ["orderIndex"] = orderIndex,
            ["prescribedSnapshot"] = new JsonObject
            {
                ["target"] = target, ["setCount"] = 3, ["restSeconds"] = 90, ["catalogVersion"] = 1, ["exerciseId"] = exerciseId.ToString(),
            },
        };

    private static JsonObject Goal(Guid lineageId, string indicatorId, Guid exerciseId, int target, bool pinned, Guid? unlockAfter = null) =>
        new()
        {
            ["planLineageId"] = lineageId.ToString(), ["title"] = "Seed goal", ["indicatorId"] = indicatorId,
            ["exerciseId"] = exerciseId.ToString(), ["target"] = new JsonObject { ["value"] = target },
            ["unlockAfterGoalId"] = unlockAfter?.ToString(), ["status"] = "active", ["pinned"] = pinned,
        };

    /// <summary>
    /// The parents and rule states fixtures/validation/business_rules.json describes in its "given" texts,
    /// for one user: exactly 50 plans, three followed lineages from 2026-11-08, three pinned goals in
    /// lineage c7…0001, goal c8…0001 unlocking after c8…0002, and phase c9…0028 in lineage c7…0004.
    /// </summary>
    private static List<JsonObject> World()
    {
        var mutations = new List<JsonObject>
        {
            Upsert("training_plan", Id("c7", 1), Plan("Seed plan 1")),
            Upsert("training_plan", Id("c7", 4), Plan("Seed plan 4")),
            Upsert("plan_phase", Id("c9", 28), new JsonObject { ["planId"] = Id("c7", 4).ToString(), ["orderIndex"] = 0, ["name"] = "Seed", ["weeks"] = 4 }),
            Upsert("planned_workout", Id("c3", 1), new JsonObject { ["planId"] = Id("c7", 1).ToString(), ["weekday"] = 1, ["orderIndex"] = 0 }),
            Upsert("workout_session", Id("d6", 1), Session()),
            Upsert("exercise_execution", Id("c5", 1), Execution(Id("d6", 1), TuckPlanche, 0, new JsonObject { ["kind"] = "static_hold", ["holdSeconds"] = 12 })),
            Upsert("exercise_execution", Id("c5", 2), Execution(Id("d6", 1), PullUp, 1, new JsonObject { ["kind"] = "reps", ["repMin"] = 5, ["repMax"] = 8 })),
            Upsert("exercise_execution", Guid.Parse("77777777-7777-4777-8777-777777777777"),
                Execution(Id("d6", 1), TuckPlanche, 2, new JsonObject { ["kind"] = "static_hold", ["holdSeconds"] = 12 })),
            Upsert("plan_goal", Id("c8", 2), Goal(Id("c7", 1), "best_set_reps", PullUp, 8, pinned: false)),
            Upsert("plan_goal", Id("c8", 1), Goal(Id("c7", 1), "best_set_reps", PullUp, 10, pinned: false, unlockAfter: Id("c8", 2))),
            Upsert("plan_goal", Id("c8", 23), Goal(Id("c7", 1), "best_hold_seconds", TuckPlanche, 15, pinned: false)),
        };
        for (var n = 91; n <= 93; n++)
        {
            mutations.Add(Upsert("plan_goal", Id("c8", n), Goal(Id("c7", 1), "best_hold_seconds", TuckPlanche, 20, pinned: true)));
            mutations.Add(Upsert("training_plan", Id("c7", n), Plan("Followed plan")));
            mutations.Add(Upsert("plan_activation", Id("c6", n), new JsonObject
            {
                ["planLineageId"] = Id("c7", n).ToString(), ["fromDate"] = "2026-11-08", ["timezone"] = TimeZone,
            }));
        }

        // 5 plans so far; 45 more makes the 50 of plan_count_limit_exceeded.
        for (var n = 101; n <= 145; n++)
        {
            mutations.Add(Upsert("training_plan", Id("c7", n), Plan("Filler plan")));
        }

        return mutations;
    }

    // ---- transport ---------------------------------------------------------------------------------

    private static string PushBody(Guid deviceId, IEnumerable<JsonObject> mutations) =>
        new JsonObject { ["deviceId"] = deviceId.ToString(), ["mutations"] = new JsonArray(mutations.Select(m => (JsonNode)m.DeepClone()).ToArray()) }
            .ToJsonString();

    private static Task<HttpResponseMessage> PostAsync(HttpClient client, string body, string contentType = "application/json")
    {
        var content = new StringContent(body, Encoding.UTF8);
        content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
        return client.PostAsync(Push, content);
    }

    private static Task<HttpResponseMessage> PushAsync(HttpClient client, Guid deviceId, params JsonObject[] mutations) =>
        PostAsync(client, PushBody(deviceId, mutations));

    private static async Task<JsonElement[]> ReceiptsAsync(HttpResponseMessage response)
    {
        var body = await response.Content.ReadAsStringAsync();
        response.StatusCode.ShouldBe(HttpStatusCode.OK, body);
        response.Content.Headers.ContentType?.MediaType.ShouldBe("application/json");
        using var document = JsonDocument.Parse(body);
        return document.RootElement.GetProperty("results").EnumerateArray().Select(r => r.Clone()).ToArray();
    }

    private static async Task<JsonElement> PushOneAsync(HttpClient client, Guid deviceId, JsonObject mutation)
    {
        var receipts = await ReceiptsAsync(await PushAsync(client, deviceId, mutation));
        receipts.Length.ShouldBe(1);
        receipts[0].GetProperty("mutationId").GetString().ShouldBe(mutation["mutationId"]!.GetValue<string>());
        return receipts[0];
    }

    private static async Task SeedAsync(HttpClient client, Guid deviceId, IReadOnlyList<JsonObject> mutations)
    {
        foreach (var chunk in mutations.Chunk(100))
        {
            var receipts = await ReceiptsAsync(await PushAsync(client, deviceId, chunk));
            receipts.Length.ShouldBe(chunk.Length);
            foreach (var receipt in receipts)
            {
                Status(receipt).ShouldBe("applied", receipt.GetRawText());
            }
        }
    }

    private static async Task<JsonElement> AssertProblemAsync(HttpResponseMessage response, HttpStatusCode status, string code)
    {
        var body = await response.Content.ReadAsStringAsync();
        response.StatusCode.ShouldBe(status, body);
        response.Content.Headers.ContentType?.MediaType.ShouldBe("application/problem+json");
        using var document = JsonDocument.Parse(body);
        var problem = document.RootElement.Clone();
        problem.GetProperty("code").GetString().ShouldBe(code);
        problem.GetProperty("traceId").GetString().ShouldNotBeNullOrWhiteSpace();
        return problem;
    }

    private static string? Status(JsonElement receipt) => receipt.GetProperty("status").GetString();

    private static string? Code(JsonElement receipt) =>
        receipt.GetProperty("error") is { ValueKind: JsonValueKind.Object } error ? error.GetProperty("code").GetString() : null;

    private static string? Field(JsonElement receipt) =>
        receipt.GetProperty("error") is { ValueKind: JsonValueKind.Object } error
        && error.TryGetProperty("details", out var details) && details.ValueKind == JsonValueKind.Object
            ? details.GetProperty("field").GetString()
            : null;

    private static bool Retryable(JsonElement receipt) => receipt.GetProperty("error").GetProperty("retryable").GetBoolean();

    private static async Task<JsonObject> FixtureAsync(params string[] path)
    {
        var node = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine([RepoPaths.RepoRoot, "fixtures", .. path])))!.AsObject();
        node.Remove("_comment");
        return node;
    }

    // ---- request-level outcomes --------------------------------------------------------------------

    [Fact]
    public async Task Push_requires_authentication()
    {
        var setup = await SetupAsync("sync_auth");
        await using var factory = Factory(setup);
        using var anonymous = factory.CreateClient();

        (await PushAsync(anonymous, Guid.NewGuid(), Upsert("body_measurement", Guid.NewGuid(), Body(70m)))).StatusCode
            .ShouldBe(HttpStatusCode.Unauthorized);
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM devices")).ShouldBe(0);
    }

    [Fact]
    public async Task Token_for_a_missing_user_row_is_404_and_writes_nothing()
    {
        var setup = await SetupAsync("sync_nouser");
        await using var factory = Factory(setup);
        using var ghost = Client(factory, setup, Guid.NewGuid());

        await AssertProblemAsync(await PushAsync(ghost, Guid.NewGuid(), Upsert("body_measurement", Guid.NewGuid(), Body(70m))),
            HttpStatusCode.NotFound, "user_not_found");
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM devices")).ShouldBe(0);
    }

    [Fact]
    public async Task Malformed_requests_are_rejected_as_a_whole_before_any_write()
    {
        var setup = await SetupAsync("sync_malformed");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var device = Guid.NewGuid();
        var valid = PushBody(device, [Upsert("body_measurement", Guid.NewGuid(), Body(70m))]);

        await AssertProblemAsync(await PostAsync(client, valid, "text/plain"), HttpStatusCode.UnsupportedMediaType, "unsupported_media_type");
        var padded = JsonNode.Parse(valid)!.AsObject();
        padded["pad"] = new string('x', 1024 * 1024);
        await AssertProblemAsync(await PostAsync(client, padded.ToJsonString()), HttpStatusCode.RequestEntityTooLarge, "payload_too_large");
        await AssertProblemAsync(await PostAsync(client, "{\"deviceId\":"), HttpStatusCode.BadRequest, "bad_request");

        var problem = await AssertProblemAsync(await PostAsync(client, PushBody(device, [])), HttpStatusCode.BadRequest, "validation_failed");
        problem.GetProperty("errors").TryGetProperty("mutations", out _).ShouldBeTrue();
        var tooMany = Enumerable.Range(0, 101).Select(_ => Upsert("body_measurement", Guid.NewGuid(), Body(70m)));
        await AssertProblemAsync(await PostAsync(client, PushBody(device, tooMany)), HttpStatusCode.BadRequest, "validation_failed");
        await AssertProblemAsync(await PostAsync(client, padded.ToJsonString().Replace(new string('x', 1024 * 1024), "x", StringComparison.Ordinal)),
            HttpStatusCode.BadRequest, "validation_failed");
        var noBaseVersion = Upsert("body_measurement", Guid.NewGuid(), Body(70m));
        noBaseVersion.Remove("baseVersion");
        problem = await AssertProblemAsync(await PushAsync(client, device, noBaseVersion), HttpStatusCode.BadRequest, "validation_failed");
        problem.GetProperty("errors").TryGetProperty("mutations[0].baseVersion", out _).ShouldBeTrue();

        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM devices")).ShouldBe(0);
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM sync_mutations")).ShouldBe(0);
    }

    [Fact]
    public async Task Device_registered_to_another_user_is_409()
    {
        var setup = await SetupAsync("sync_device");
        await using var factory = Factory(setup);
        using var clientA = Client(factory, setup, setup.UserA);
        using var clientB = Client(factory, setup, setup.UserB);
        var device = Guid.NewGuid();

        Status(await PushOneAsync(clientA, device, Upsert("body_measurement", Guid.NewGuid(), Body(70m)))).ShouldBe("applied");
        await AssertProblemAsync(await PushAsync(clientB, device, Upsert("body_measurement", Guid.NewGuid(), Body(71m))),
            HttpStatusCode.Conflict, "device_owner_mismatch");

        (await ScalarAsync<long>(setup.ConnectionString, $"SELECT count(*) FROM body_measurements WHERE user_id = '{setup.UserB}'")).ShouldBe(0);
        (await ScalarAsync<long>(setup.ConnectionString, $"SELECT count(*) FROM sync_mutations WHERE user_id = '{setup.UserB}'")).ShouldBe(0);
    }

    // ---- idempotency ---------------------------------------------------------------------------------

    [Fact]
    public async Task Same_push_sent_ten_times_concurrently_writes_once_and_replays_the_receipt()
    {
        var setup = await SetupAsync("sync_replay");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var device = Guid.NewGuid();
        var mutation = Upsert("body_measurement", Guid.NewGuid(), Body(72.35m));

        // A brand-new device and user: also races the device registration and user_sync_state creation.
        var receipts = (await Task.WhenAll(Enumerable.Range(0, 10).Select(_ => PushOneAsync(client, device, mutation)))).ToList();

        receipts.Count(r => Status(r) == "applied").ShouldBe(1);
        receipts.Count(r => Status(r) == "duplicate").ShouldBe(9);
        var applied = JsonNode.Parse(receipts.Single(r => Status(r) == "applied").GetRawText())!.AsObject();
        applied["serverVersion"]!.GetValue<long>().ShouldBe(1);
        applied["error"].ShouldBeNull();
        foreach (var duplicate in receipts.Where(r => Status(r) == "duplicate"))
        {
            var replayed = JsonNode.Parse(duplicate.GetRawText())!.AsObject();
            replayed["status"] = "applied";
            JsonNode.DeepEquals(replayed, applied).ShouldBeTrue(duplicate.GetRawText());
        }

        // clientChangedAt is not part of the fingerprint (ADR-069): a retry with a new timestamp is still a duplicate.
        var retried = mutation.DeepClone().AsObject();
        retried["clientChangedAt"] = "2026-11-07T09:30:00Z";
        Status(await PushOneAsync(client, device, retried)).ShouldBe("duplicate");

        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM body_measurements")).ShouldBe(1);
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM sync_mutations")).ShouldBe(1);
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM sync_change_log")).ShouldBe(1);
        (await ScalarAsync<long>(setup.ConnectionString, $"SELECT last_seq FROM user_sync_state WHERE user_id = '{setup.UserA}'")).ShouldBe(1);
    }

    [Fact]
    public async Task Changed_mutation_under_a_used_mutation_id_is_rejected_and_not_stored()
    {
        var setup = await SetupAsync("sync_reuse");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var device = Guid.NewGuid();
        var entity = Guid.NewGuid();
        var mutationId = Guid.NewGuid();

        Status(await PushOneAsync(client, device, Upsert("body_measurement", entity, Body(72.35m), mutationId: mutationId))).ShouldBe("applied");
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var reused = await PushOneAsync(client, device, Upsert("body_measurement", entity, Body(80m), mutationId: mutationId));
            Status(reused).ShouldBe("rejected");
            Code(reused).ShouldBe("mutation_id_reused");
            Retryable(reused).ShouldBeFalse();
        }

        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM sync_mutations")).ShouldBe(1);
        (await ScalarAsync<string>(setup.ConnectionString, "SELECT status FROM sync_mutations")).ShouldBe("applied");
        (await ScalarAsync<decimal>(setup.ConnectionString, $"SELECT value FROM body_measurements WHERE id = '{entity}'")).ShouldBe(72.35m);
    }

    // ---- versioning, dependencies, ownership ----------------------------------------------------------

    [Fact]
    public async Task Stale_base_version_is_a_stored_conflict_with_the_server_entity()
    {
        var setup = await SetupAsync("sync_conflict");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var device = Guid.NewGuid();
        var entity = Guid.NewGuid();
        Status(await PushOneAsync(client, device, Upsert("body_measurement", entity, Body(72.35m)))).ShouldBe("applied");

        var stale = Upsert("body_measurement", entity, Body(73m), baseVersion: 0);
        var conflict = await PushOneAsync(client, device, stale);
        Status(conflict).ShouldBe("conflict");
        Code(conflict).ShouldBe("version_conflict");
        Retryable(conflict).ShouldBeFalse();
        conflict.GetProperty("serverVersion").GetInt64().ShouldBe(1);
        conflict.GetProperty("serverEntity").GetProperty("id").GetGuid().ShouldBe(entity);
        Status(await PushOneAsync(client, device, stale)).ShouldBe("duplicate");

        var current = await PushOneAsync(client, device, Upsert("body_measurement", entity, Body(73m), baseVersion: 1));
        Status(current).ShouldBe("applied");
        current.GetProperty("serverVersion").GetInt64().ShouldBe(2);

        (await ScalarAsync<decimal>(setup.ConnectionString, $"SELECT value FROM body_measurements WHERE id = '{entity}'")).ShouldBe(73m);
        (await ScalarAsync<string>(setup.ConnectionString, """
            SELECT string_agg(status, ',' ORDER BY created_at, status) FROM sync_mutations
            """)).ShouldBe("applied,conflict,applied");
    }

    [Fact]
    public async Task Missing_parent_is_retryable_and_applies_once_the_parent_arrives()
    {
        var setup = await SetupAsync("sync_dependency");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var device = Guid.NewGuid();
        var session = Guid.NewGuid();
        var execution = Upsert("exercise_execution", Guid.NewGuid(),
            Execution(session, PullUp, 0, new JsonObject { ["kind"] = "reps", ["repMin"] = 5, ["repMax"] = 8 }));

        var missing = await PushOneAsync(client, device, execution);
        Status(missing).ShouldBe("conflict");
        Code(missing).ShouldBe("dependency_missing");
        Field(missing).ShouldBe("sessionId");
        Retryable(missing).ShouldBeTrue();
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM sync_mutations")).ShouldBe(0);

        // Parent and the same child mutation (same mutationId) in one later push, parent first.
        var receipts = await ReceiptsAsync(await PushAsync(client, device, Upsert("workout_session", session, Session()), execution));
        receipts.Select(Status).ShouldBe(["applied", "applied"]);
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM exercise_executions")).ShouldBe(1);
    }

    [Fact]
    public async Task Another_users_entity_id_or_parent_is_a_cross_user_reference()
    {
        var setup = await SetupAsync("sync_crossuser");
        await using var factory = Factory(setup);
        using var clientA = Client(factory, setup, setup.UserA);
        using var clientB = Client(factory, setup, setup.UserB);
        var body = Guid.NewGuid();
        var session = Guid.NewGuid();
        await SeedAsync(clientA, Guid.NewGuid(), [Upsert("body_measurement", body, Body(72.35m)), Upsert("workout_session", session, Session())]);

        var deviceB = Guid.NewGuid();
        var entity = await PushOneAsync(clientB, deviceB, Upsert("body_measurement", body, Body(90m), baseVersion: 1));
        Status(entity).ShouldBe("rejected");
        Code(entity).ShouldBe("cross_user_reference");
        Field(entity).ShouldBe("entityId");

        var parent = await PushOneAsync(clientB, deviceB, Upsert("exercise_execution", Guid.NewGuid(),
            Execution(session, PullUp, 0, new JsonObject { ["kind"] = "reps", ["repMin"] = 5, ["repMax"] = 8 })));
        Status(parent).ShouldBe("rejected");
        Code(parent).ShouldBe("cross_user_reference");
        Field(parent).ShouldBe("sessionId");

        (await ScalarAsync<decimal>(setup.ConnectionString, $"SELECT value FROM body_measurements WHERE id = '{body}'")).ShouldBe(72.35m);
        (await ScalarAsync<long>(setup.ConnectionString, $"SELECT count(*) FROM sync_change_log WHERE user_id = '{setup.UserB}'")).ShouldBe(0);
    }

    [Fact]
    public async Task Unknown_entity_type_is_forbidden_not_stored_and_does_not_fail_the_batch()
    {
        var setup = await SetupAsync("sync_forbidden");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var forbidden = Upsert("ai_analysis", Guid.NewGuid(), new JsonObject());

        for (var attempt = 0; attempt < 2; attempt++)
        {
            var receipts = await ReceiptsAsync(await PushAsync(client, Guid.NewGuid(), forbidden, Upsert("body_measurement", Guid.NewGuid(), Body(70m))));
            Status(receipts[0]).ShouldBe("rejected");
            Code(receipts[0]).ShouldBe("forbidden_entity");
            Field(receipts[0]).ShouldBe("entityType");
            Status(receipts[1]).ShouldBe("applied");
        }

        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM sync_mutations WHERE entity_type = 'ai_analysis'")).ShouldBe(0);
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM sync_mutations")).ShouldBe(2);
    }

    [Fact]
    public async Task Delete_leaves_a_tombstone_and_a_delete_change()
    {
        var setup = await SetupAsync("sync_delete");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var device = Guid.NewGuid();
        var entity = Guid.NewGuid();
        Status(await PushOneAsync(client, device, Upsert("body_measurement", entity, Body(72.35m)))).ShouldBe("applied");

        var delete = Delete("body_measurement", entity, baseVersion: 1);
        var deleted = await PushOneAsync(client, device, delete);
        Status(deleted).ShouldBe("applied");
        deleted.GetProperty("serverVersion").GetInt64().ShouldBe(2);
        Status(await PushOneAsync(client, device, delete)).ShouldBe("duplicate");

        (await ScalarAsync<bool>(setup.ConnectionString, $"SELECT deleted_at IS NOT NULL FROM body_measurements WHERE id = '{entity}'")).ShouldBeTrue();
        (await ScalarAsync<string>(setup.ConnectionString, $"""
            SELECT string_agg(seq || ':' || operation || ':' || server_version, ',' ORDER BY seq) FROM sync_change_log WHERE user_id = '{setup.UserA}'
            """)).ShouldBe("1:upsert:1,2:delete:2");

        // A deleted row cannot be written again.
        var again = await PushOneAsync(client, device, Upsert("body_measurement", entity, Body(70m), baseVersion: 2));
        Status(again).ShouldBe("conflict");
        Code(again).ShouldBe("version_conflict");
    }

    [Fact]
    public async Task Concurrent_pushes_of_one_user_get_a_gap_free_change_log()
    {
        var setup = await SetupAsync("sync_seq");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);

        var pushes = Enumerable.Range(0, 5).Select(_ =>
            PushAsync(client, Guid.NewGuid(), Enumerable.Range(0, 4).Select(i => Upsert("body_measurement", Guid.NewGuid(), Body(70m + i))).ToArray()));
        foreach (var response in await Task.WhenAll(pushes))
        {
            (await ReceiptsAsync(response)).Select(Status).ShouldAllBe(s => s == "applied");
        }

        (await ScalarAsync<string>(setup.ConnectionString, $"""
            SELECT count(*) || ',' || count(DISTINCT seq) || ',' || min(seq) || ',' || max(seq) FROM sync_change_log WHERE user_id = '{setup.UserA}'
            """)).ShouldBe("20,20,1,20");
        (await ScalarAsync<long>(setup.ConnectionString, $"SELECT last_seq FROM user_sync_state WHERE user_id = '{setup.UserA}'")).ShouldBe(20);
    }

    [Fact]
    public async Task Body_measurement_values_never_reach_the_logs()
    {
        var setup = await SetupAsync("sync_privacy");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);

        var receipts = await ReceiptsAsync(await PushAsync(client, Guid.NewGuid(),
            Upsert("body_measurement", Guid.NewGuid(), Body(72.35m)), Upsert("body_measurement", Guid.NewGuid(), Body(612.47m))));
        receipts.Select(Status).ShouldBe(["applied", "rejected"]);

        // ADR-064: body data is sensitive; neither the stored nor the rejected value is logged.
        factory.Logs.Entries.ShouldNotBeEmpty();
        factory.Logs.Entries.ShouldAllBe(e => !e.Contains("72.35") && !e.Contains("72,35") && !e.Contains("612.47") && !e.Contains("612,47"));
    }

    // ---- contract fixtures -----------------------------------------------------------------------------

    [Fact]
    public async Task Business_rule_fixtures_are_rejected_with_their_code_and_field()
    {
        var setup = await SetupAsync("sync_rules");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var device = Guid.NewGuid();
        var world = World();
        await SeedAsync(client, device, world);

        var fixture = await FixtureAsync("validation", "business_rules.json");
        var cases = fixture["cases"]!.AsArray();
        cases.Count.ShouldBe(29);
        cases.Select(c => c!["mutation"]!["mutationId"]!.GetValue<string>()).ShouldBeUnique();
        var mismatches = new List<string>();
        foreach (var item in cases)
        {
            var expect = item!["expect"]!;
            var receipt = await PushOneAsync(client, device, item["mutation"]!.AsObject());
            var actual = (Status(receipt), Code(receipt), Field(receipt));
            var expected = (expect["status"]!.GetValue<string>(), expect["code"]!.GetValue<string>(), expect["field"]?.GetValue<string>());
            if (actual != expected)
            {
                mismatches.Add($"{item["name"]}: expected {expected}, got {receipt.GetRawText()}");
            }
        }

        mismatches.ShouldBeEmpty(string.Join(Environment.NewLine, mismatches));

        // Every case was rejected inside its savepoint: the seeded world is unchanged.
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM sync_change_log")).ShouldBe(world.Count);
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM training_plans WHERE deleted_at IS NULL")).ShouldBe(50);
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM sync_mutations WHERE status = 'rejected'")).ShouldBe(29);
    }

    [Fact]
    public async Task Schema_rejection_fixtures_are_validation_failed_receipts()
    {
        var setup = await SetupAsync("sync_schema");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var device = Guid.NewGuid();

        var fixture = await FixtureAsync("validation", "schema_rejections.json");
        var cases = fixture["cases"]!.AsArray();
        cases.Count.ShouldBe(30);
        cases.Select(c => c!["mutation"]!["mutationId"]!.GetValue<string>()).ShouldBeUnique();
        var mismatches = new List<string>();
        foreach (var item in cases)
        {
            var receipt = await PushOneAsync(client, device, item!["mutation"]!.AsObject());
            if (Status(receipt) != "rejected" || Code(receipt) != "validation_failed")
            {
                mismatches.Add($"{item["name"]}: {receipt.GetRawText()}");
            }
        }

        mismatches.ShouldBeEmpty(string.Join(Environment.NewLine, mismatches));
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM sync_change_log")).ShouldBe(0);
    }

    [Fact]
    public async Task Sync_push_fixture_applies_once_its_parents_exist()
    {
        var setup = await SetupAsync("sync_fixture");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        await SeedAsync(client, Guid.NewGuid(), World());

        var fixture = await FixtureAsync("sync_push.json");
        var receipts = await ReceiptsAsync(await PostAsync(client, fixture.ToJsonString()));

        receipts.Length.ShouldBe(1);
        Status(receipts[0]).ShouldBe("applied", receipts[0].GetRawText());
        receipts[0].GetProperty("serverVersion").GetInt64().ShouldBe(1);
        (await ScalarAsync<long>(setup.ConnectionString,
            "SELECT actual_hold_ms FROM set_results WHERE id = '66666666-6666-4666-8666-666666666666'")).ShouldBe(12000);
    }

    [Theory]
    [InlineData("body_measurement_sync_push.sample.json")]
    [InlineData("plan_activation_sync_push.sample.json")]
    [InlineData("plan_goals_sync_push.sample.json")]
    public async Task Self_contained_samples_apply_in_order(string sample)
    {
        var setup = await SetupAsync("sync_sample");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);

        var receipts = await ReceiptsAsync(await PostAsync(client, (await FixtureAsync("samples", sample)).ToJsonString()));

        receipts.ShouldNotBeEmpty();
        foreach (var receipt in receipts)
        {
            Status(receipt).ShouldBe("applied", receipt.GetRawText());
        }
    }

    private static async Task ExecuteAsync(string connectionString, string sql, params object?[] args)
    {
        await using var dataSource = NpgsqlDataSource.Create(connectionString);
        await using var command = dataSource.CreateCommand(sql);
        foreach (var arg in args)
        {
            command.Parameters.AddWithValue(arg ?? DBNull.Value);
        }

        await command.ExecuteNonQueryAsync();
    }

    private static async Task<T> ScalarAsync<T>(string connectionString, string sql)
    {
        await using var dataSource = NpgsqlDataSource.Create(connectionString);
        await using var command = dataSource.CreateCommand(sql);
        return (T)(await command.ExecuteScalarAsync())!;
    }
}
