using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Cali.Infrastructure.Auth;
using Cali.IntegrationTests.Infrastructure;
using Npgsql;

namespace Cali.IntegrationTests;

/// <summary>B1 (BE-002): GET/POST /v1/plans — auth scoping, keyset pagination, idempotent create (ADR-068).</summary>
[Collection(PostgresCollection.Name)]
public sealed class PlanEndpointTests(PostgresFixture postgres)
{
    private static readonly Uri Plans = new("/v1/plans", UriKind.Relative);

    private sealed record Setup(string ConnectionString, string SigningKey, Guid UserA, Guid UserB, Guid PullUp);

    private async Task<Setup> SetupAsync(string prefix)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync(prefix);
        var setup = new Setup(cs, DevSigningKey.Generate(), Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid());
        await ExecuteAsync(cs, "INSERT INTO users (id) VALUES ($1), ($2)", setup.UserA, setup.UserB);
        await ExecuteAsync(cs, """
            INSERT INTO exercise_catalog (id, slug, name, exercise_type, is_published)
            VALUES ($1, 'plan-pull-up', 'Pull-up', 'reps', true)
            """, setup.PullUp);
        return setup;
    }

    private static CaliApiFactory Factory(Setup setup, int? syncPermitLimit = null)
    {
        var settings = new Dictionary<string, string?>
        {
            ["ConnectionStrings:Cali"] = setup.ConnectionString,
            ["Auth:DevTokens:SigningKey"] = setup.SigningKey,
        };
        if (syncPermitLimit is { } limit)
        {
            settings["RateLimiting:Sync:PermitLimit"] = limit.ToString(CultureInfo.InvariantCulture);
            settings["RateLimiting:Sync:WindowSeconds"] = "60";
        }

        return new CaliApiFactory("Development", settings);
    }

    private static HttpClient Client(CaliApiFactory factory, Setup setup, Guid userId)
    {
        DevSigningKey.TryParse(setup.SigningKey, out var key, out _).ShouldBeTrue();
        var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer", DevTokenFactory.Create(userId, TimeSpan.FromHours(1), DateTimeOffset.UtcNow, key));
        return client;
    }

    private static string PlanBody(Guid catalogId, Guid? planId = null, string title = "Push day", int repMin = 5, int repMax = 8) =>
        new JsonObject
        {
            ["id"] = planId ?? Guid.NewGuid(),
            ["title"] = title,
            ["workouts"] = new JsonArray(new JsonObject
            {
                ["id"] = Guid.NewGuid(),
                ["weekday"] = 1,
                ["orderIndex"] = 0,
                ["exercises"] = new JsonArray(new JsonObject
                {
                    ["id"] = Guid.NewGuid(),
                    ["exerciseId"] = catalogId,
                    ["orderIndex"] = 0,
                    ["setCount"] = 3,
                    ["target"] = new JsonObject { ["repMax"] = repMax, ["kind"] = "reps", ["repMin"] = repMin },
                    ["restSeconds"] = 90,
                }),
            }),
        }.ToJsonString();

    private static Task<HttpResponseMessage> PostAsync(
        HttpClient client, string body, Guid? key = null, string contentType = "application/json", params string[] extraKeys)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, Plans) { Content = new StringContent(body, Encoding.UTF8) };
        request.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
        if (key is { } k)
        {
            request.Headers.Add("Idempotency-Key", k.ToString());
        }

        foreach (var extra in extraKeys)
        {
            request.Headers.Add("Idempotency-Key", extra);
        }

        return client.SendAsync(request);
    }

    private static async Task<JsonElement> ReadJsonAsync(HttpResponseMessage response, HttpStatusCode expected)
    {
        var body = await response.Content.ReadAsStringAsync();
        response.StatusCode.ShouldBe(expected, body);
        using var document = JsonDocument.Parse(body);
        return document.RootElement.Clone();
    }

    private static async Task<JsonElement> AssertProblemAsync(HttpResponseMessage response, HttpStatusCode status, string code)
    {
        var problem = await ReadJsonAsync(response, status);
        response.Content.Headers.ContentType?.MediaType.ShouldBe("application/problem+json");
        problem.GetProperty("code").GetString().ShouldBe(code);
        problem.GetProperty("traceId").GetString().ShouldNotBeNullOrWhiteSpace();
        return problem;
    }

    private static async Task<JsonElement> CreateAsync(HttpClient client, Setup setup, string? title = null)
    {
        var response = await PostAsync(client, PlanBody(setup.PullUp, title: title ?? "Plan"), Guid.NewGuid());
        return await ReadJsonAsync(response, HttpStatusCode.Created);
    }

    private static async Task<JsonElement> ListAsync(HttpClient client, string query = "", HttpStatusCode expected = HttpStatusCode.OK) =>
        await ReadJsonAsync(await client.GetAsync(new Uri("/v1/plans" + query, UriKind.Relative)), expected);

    private static string[] Titles(JsonElement page) =>
        page.GetProperty("items").EnumerateArray().Select(p => p.GetProperty("title").GetString()!).ToArray();

    [Fact]
    public async Task Plans_require_authentication()
    {
        var setup = await SetupAsync("plan_auth");
        await using var factory = Factory(setup);
        using var anonymous = factory.CreateClient();

        (await anonymous.GetAsync(Plans)).StatusCode.ShouldBe(HttpStatusCode.Unauthorized);
        (await PostAsync(anonymous, PlanBody(setup.PullUp), Guid.NewGuid())).StatusCode.ShouldBe(HttpStatusCode.Unauthorized);
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM training_plans")).ShouldBe(0);
    }

    [Fact]
    public async Task Create_returns_a_root_revision_with_its_change_log_and_lists_it()
    {
        var setup = await SetupAsync("plan_create");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var planId = Guid.NewGuid();

        var response = await PostAsync(client, PlanBody(setup.PullUp, planId), Guid.NewGuid());
        var plan = await ReadJsonAsync(response, HttpStatusCode.Created);

        response.Content.Headers.ContentType?.MediaType.ShouldBe("application/json");
        plan.GetProperty("id").GetGuid().ShouldBe(planId);
        plan.GetProperty("revision").GetInt32().ShouldBe(1);
        plan.GetProperty("version").GetInt64().ShouldBe(1);
        plan.GetProperty("status").GetString().ShouldBe("current");
        plan.GetProperty("lineageId").GetGuid().ShouldBe(planId);
        plan.GetProperty("parentPlanId").ValueKind.ShouldBe(JsonValueKind.Null);
        plan.GetProperty("kind").GetString().ShouldBe("weekly");
        plan.GetProperty("primaryDiscipline").GetString().ShouldBe("calisthenics");
        var workout = plan.GetProperty("workouts")[0];
        workout.GetProperty("title").GetString().ShouldBe("");
        // Target normalized: kind first, schema field order.
        workout.GetProperty("exercises")[0].GetProperty("target").GetRawText().ShouldBe("""{"kind":"reps","repMin":5,"repMax":8}""");

        var page = await ListAsync(client);
        page.GetProperty("items").GetArrayLength().ShouldBe(1);
        JsonNode.DeepEquals(JsonNode.Parse(page.GetProperty("items")[0].GetRawText()), JsonNode.Parse(plan.GetRawText())).ShouldBeTrue();

        // docs/06: a direct write produces the same change log as a sync push, gap-free from seq 1.
        (await ScalarAsync<string>(setup.ConnectionString, $"""
            SELECT string_agg(seq || ':' || entity_type, ',' ORDER BY seq) FROM sync_change_log WHERE user_id = '{setup.UserA}'
            """)).ShouldBe("1:training_plan,2:planned_workout,3:planned_exercise");
        (await ScalarAsync<long>(setup.ConnectionString, $"SELECT last_seq FROM user_sync_state WHERE user_id = '{setup.UserA}'")).ShouldBe(3);
        (await ScalarAsync<string>(setup.ConnectionString, $"""
            SELECT payload ->> 'lineageId' FROM sync_change_log WHERE user_id = '{setup.UserA}' AND seq = 1
            """)).ShouldBe(planId.ToString());
    }

    [Fact]
    public async Task Same_key_and_request_replays_the_first_response_without_writing_again()
    {
        var setup = await SetupAsync("plan_replay");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var key = Guid.NewGuid();
        var body = PlanBody(setup.PullUp);

        var first = await ReadJsonAsync(await PostAsync(client, body, key), HttpStatusCode.Created);
        // Same request with different member order and whitespace: same canonical hash (ADR-068).
        var reordered = JsonNode.Parse(body)!.AsObject();
        var title = reordered["title"]!.DeepClone();
        reordered.Remove("title");
        reordered["title"] = title;
        var second = await ReadJsonAsync(await PostAsync(client, reordered.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), key), HttpStatusCode.Created);

        JsonNode.DeepEquals(JsonNode.Parse(first.GetRawText()), JsonNode.Parse(second.GetRawText())).ShouldBeTrue();
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM training_plans")).ShouldBe(1);
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM sync_change_log")).ShouldBe(3);

        // Same key, different request: rejected, nothing written.
        await AssertProblemAsync(await PostAsync(client, PlanBody(setup.PullUp, title: "Other"), key),
            HttpStatusCode.Conflict, "idempotency_key_reused");
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM training_plans")).ShouldBe(1);

        // Keys are scoped per user: another user's identical key is a fresh request.
        using var other = Client(factory, setup, setup.UserB);
        await ReadJsonAsync(await PostAsync(other, PlanBody(setup.PullUp), key), HttpStatusCode.Created);
    }

    [Fact]
    public async Task Taken_ids_are_a_conflict_for_any_user()
    {
        var setup = await SetupAsync("plan_conflict");
        await using var factory = Factory(setup);
        using var a = Client(factory, setup, setup.UserA);
        using var b = Client(factory, setup, setup.UserB);
        var planId = Guid.NewGuid();
        await ReadJsonAsync(await PostAsync(a, PlanBody(setup.PullUp, planId), Guid.NewGuid()), HttpStatusCode.Created);

        await AssertProblemAsync(await PostAsync(a, PlanBody(setup.PullUp, planId), Guid.NewGuid()), HttpStatusCode.Conflict, "conflict");
        // Another user's id: same answer, and the response does not reveal whose plan it is.
        var problem = await AssertProblemAsync(await PostAsync(b, PlanBody(setup.PullUp, planId), Guid.NewGuid()), HttpStatusCode.Conflict, "conflict");
        problem.GetRawText().ShouldNotContain(setup.UserA.ToString());
        (await ScalarAsync<long>(setup.ConnectionString, $"SELECT count(*) FROM sync_change_log WHERE user_id = '{setup.UserB}'")).ShouldBe(0);
    }

    [Fact]
    public async Task Invalid_requests_are_rejected_with_field_paths_and_store_nothing()
    {
        var setup = await SetupAsync("plan_invalid");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var key = Guid.NewGuid();

        var problem = await AssertProblemAsync(await PostAsync(client, PlanBody(setup.PullUp, repMin: 10, repMax: 5), key),
            HttpStatusCode.BadRequest, "validation_failed");
        problem.GetProperty("errors").TryGetProperty("workouts[0].exercises[0].target.repMax", out _).ShouldBeTrue(problem.GetRawText());

        var unknownExercise = await AssertProblemAsync(await PostAsync(client, PlanBody(Guid.NewGuid()), Guid.NewGuid()),
            HttpStatusCode.BadRequest, "validation_failed");
        unknownExercise.GetProperty("errors").TryGetProperty("workouts[0].exercises[0].exerciseId", out _).ShouldBeTrue();

        var wrongType = await AssertProblemAsync(await PostAsync(client, """{"id":"8d7c0a1e-0000-4000-8000-000000000001","title":5,"workouts":[]}""", Guid.NewGuid()),
            HttpStatusCode.BadRequest, "validation_failed");
        wrongType.GetProperty("errors").TryGetProperty("title", out _).ShouldBeTrue();

        await AssertProblemAsync(await PostAsync(client, "[]", Guid.NewGuid()), HttpStatusCode.BadRequest, "validation_failed");
        await AssertProblemAsync(await PostAsync(client, "{\"id\":", Guid.NewGuid()), HttpStatusCode.BadRequest, "bad_request");

        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM http_idempotency_keys")).ShouldBe(0);
        // A failed request is not remembered: the same key with a corrected body succeeds.
        await ReadJsonAsync(await PostAsync(client, PlanBody(setup.PullUp), key), HttpStatusCode.Created);
    }

    [Fact]
    public async Task Headers_media_type_and_size_are_checked_before_the_body()
    {
        var setup = await SetupAsync("plan_headers");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var body = PlanBody(setup.PullUp);

        await AssertProblemAsync(await PostAsync(client, body), HttpStatusCode.BadRequest, "bad_request");
        await AssertProblemAsync(await PostAsync(client, body, null, "application/json", "not-a-uuid"), HttpStatusCode.BadRequest, "bad_request");
        await AssertProblemAsync(await PostAsync(client, body, Guid.NewGuid(), "application/json", Guid.NewGuid().ToString()),
            HttpStatusCode.BadRequest, "bad_request");
        await AssertProblemAsync(await PostAsync(client, body, Guid.NewGuid(), "text/plain"), HttpStatusCode.UnsupportedMediaType, "unsupported_media_type");
        await AssertProblemAsync(await PostAsync(client, body, Guid.NewGuid(), "application/json; charset=utf-16"),
            HttpStatusCode.UnsupportedMediaType, "unsupported_media_type");
        var oversized = "{\"title\":\"" + new string('a', 1024 * 1024) + "\"}";
        await AssertProblemAsync(await PostAsync(client, oversized, Guid.NewGuid()), HttpStatusCode.RequestEntityTooLarge, "payload_too_large");

        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM training_plans")).ShouldBe(0);
    }

    [Fact]
    public async Task Plan_count_limit_is_enforced()
    {
        var setup = await SetupAsync("plan_limit");
        await ExecuteAsync(setup.ConnectionString, """
            INSERT INTO training_plans (id, user_id, title)
            SELECT gen_random_uuid(), $1, 'Plan ' || g FROM generate_series(1, 50) AS g
            """, setup.UserA);
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);

        await AssertProblemAsync(await PostAsync(client, PlanBody(setup.PullUp), Guid.NewGuid()), HttpStatusCode.Conflict, "plan_count_limit");

        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM training_plans")).ShouldBe(50);
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM sync_change_log")).ShouldBe(0);
    }

    [Fact]
    public async Task Unprovisioned_user_cannot_create_plans()
    {
        var setup = await SetupAsync("plan_no_user");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, Guid.NewGuid());

        await AssertProblemAsync(await PostAsync(client, PlanBody(setup.PullUp), Guid.NewGuid()), HttpStatusCode.NotFound, "user_not_found");
        (await ListAsync(client)).GetProperty("items").GetArrayLength().ShouldBe(0);
    }

    [Fact]
    public async Task Cursor_pagination_is_stable_when_rows_are_inserted_mid_way()
    {
        var setup = await SetupAsync("plan_page");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        foreach (var title in new[] { "P1", "P2", "P3", "P4", "P5" })
        {
            await CreateAsync(client, setup, title);
        }

        var first = await ListAsync(client, "?limit=2");
        Titles(first).ShouldBe(["P1", "P2"]);
        first.GetProperty("hasMore").GetBoolean().ShouldBeTrue();
        var cursor = first.GetProperty("nextCursor").GetString();

        // One row created after the first page (sorts last), one back-dated row (sorts before the cursor).
        await CreateAsync(client, setup, "P6");
        await ExecuteAsync(setup.ConnectionString, """
            INSERT INTO training_plans (id, user_id, title, created_at) VALUES (gen_random_uuid(), $1, 'P0', now() - interval '1 day')
            """, setup.UserA);

        var seen = new List<string>(Titles(first));
        while (cursor is not null)
        {
            var page = await ListAsync(client, $"?limit=2&cursor={Uri.EscapeDataString(cursor)}");
            seen.AddRange(Titles(page));
            cursor = page.GetProperty("hasMore").GetBoolean() ? page.GetProperty("nextCursor").GetString() : null;
        }

        seen.ShouldBe(["P1", "P2", "P3", "P4", "P5", "P6"]);
        var last = await ListAsync(client, "?limit=100");
        last.GetProperty("hasMore").GetBoolean().ShouldBeFalse();
        last.GetProperty("nextCursor").ValueKind.ShouldBe(JsonValueKind.Null);
    }

    [Fact]
    public async Task Users_only_see_their_own_plans()
    {
        var setup = await SetupAsync("plan_idor");
        await using var factory = Factory(setup);
        using var a = Client(factory, setup, setup.UserA);
        using var b = Client(factory, setup, setup.UserB);
        await CreateAsync(a, setup, "A1");
        await CreateAsync(a, setup, "A2");
        await CreateAsync(b, setup, "B1");

        var pageA = await ListAsync(a, "?limit=1");
        Titles(pageA).ShouldBe(["A1"]);
        Titles(await ListAsync(b)).ShouldBe(["B1"]);

        // A's cursor replayed by B still only reads B's rows.
        var cursor = pageA.GetProperty("nextCursor").GetString()!;
        Titles(await ListAsync(b, $"?cursor={Uri.EscapeDataString(cursor)}")).ShouldNotContain("A2");
    }

    [Theory]
    [InlineData("?limit=0")]
    [InlineData("?limit=101")]
    [InlineData("?limit=abc")]
    [InlineData("?limit=+5")]
    [InlineData("?limit=1&limit=2")]
    [InlineData("?cursor=bm90LWEtY3Vyc29y")]
    [InlineData("?cursor=a&cursor=b")]
    public async Task Invalid_query_parameters_are_rejected(string query)
    {
        var setup = await SetupAsync("plan_query");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);

        await AssertProblemAsync(await client.GetAsync(new Uri("/v1/plans" + query, UriKind.Relative)), HttpStatusCode.BadRequest, "bad_request");
    }

    [Fact]
    public async Task Plans_are_rate_limited_per_user()
    {
        var setup = await SetupAsync("plan_429");
        await using var factory = Factory(setup, syncPermitLimit: 1);
        using var a = Client(factory, setup, setup.UserA);
        using var b = Client(factory, setup, setup.UserB);

        (await a.GetAsync(Plans)).StatusCode.ShouldBe(HttpStatusCode.OK);
        await AssertProblemAsync(await a.GetAsync(Plans), HttpStatusCode.TooManyRequests, "rate_limited");
        (await b.GetAsync(Plans)).StatusCode.ShouldBe(HttpStatusCode.OK);
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
