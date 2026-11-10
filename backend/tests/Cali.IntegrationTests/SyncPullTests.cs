using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Cali.Api.Sync;
using Cali.Infrastructure.Auth;
using Cali.IntegrationTests.Infrastructure;
using Cali.Tests.Shared;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting.Internal;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

namespace Cali.IntegrationTests;

/// <summary>
/// B3 (BE-004): GET /v1/sync/pull — the user's change feed in commit order behind a signed, user-bound cursor
/// (docs/08 section 4 and 7, ADR-070). Data is written through the real endpoints (push, POST /v1/plans).
/// </summary>
[Collection(PostgresCollection.Name)]
public sealed class SyncPullTests(PostgresFixture postgres)
{
    private const string SeedAt = "2026-11-07T08:00:00Z";

    // fixtures/exercise_catalog.json
    private static readonly Guid TuckPlanche = Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1");

    private sealed record Setup(string ConnectionString, string SigningKey, Guid UserA, Guid UserB);

    private sealed record Page(JsonElement[] Changes, string NextCursor, bool HasMore);

    private async Task<Setup> SetupAsync(string prefix)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync(prefix);
        var setup = new Setup(cs, DevSigningKey.Generate(), Guid.NewGuid(), Guid.NewGuid());
        await ExecuteAsync(cs, "INSERT INTO users (id) VALUES ($1), ($2)", setup.UserA, setup.UserB);
        await ExecuteAsync(cs, """
            INSERT INTO exercise_catalog (id, slug, name, exercise_type, discipline, is_published)
            VALUES ($1, 'tuck-planche', 'Tuck planche', 'static_hold', 'calisthenics', true)
            """, TuckPlanche);
        return setup;
    }

    private static CaliApiFactory Factory(Setup setup, params (string Key, string? Value)[] extra)
    {
        var settings = new Dictionary<string, string?>
        {
            ["ConnectionStrings:Cali"] = setup.ConnectionString,
            ["Auth:DevTokens:SigningKey"] = setup.SigningKey,
            ["RateLimiting:Sync:PermitLimit"] = "100000",
            ["RateLimiting:Sync:WindowSeconds"] = "60",
        };
        foreach (var (key, value) in extra)
        {
            settings[key] = value;
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

    // ---- writes ---------------------------------------------------------------------------------------

    private static JsonObject Upsert(Guid entityId, decimal value, long baseVersion = 0) =>
        new()
        {
            ["mutationId"] = Guid.NewGuid().ToString(),
            ["entityType"] = "body_measurement",
            ["entityId"] = entityId.ToString(),
            ["action"] = "upsert",
            ["baseVersion"] = baseVersion,
            ["clientChangedAt"] = SeedAt,
            ["payload"] = new JsonObject
            {
                ["id"] = entityId.ToString(), ["kind"] = "weight", ["value"] = value, ["measuredAt"] = "2026-11-07T06:45:00Z",
            },
        };

    private static JsonObject Delete(Guid entityId, long baseVersion) =>
        new()
        {
            ["mutationId"] = Guid.NewGuid().ToString(),
            ["entityType"] = "body_measurement",
            ["entityId"] = entityId.ToString(),
            ["action"] = "delete",
            ["baseVersion"] = baseVersion,
            ["clientChangedAt"] = SeedAt,
            ["payload"] = new JsonObject { ["id"] = entityId.ToString(), ["deletedAt"] = SeedAt },
        };

    private static async Task PushAsync(HttpClient client, Guid deviceId, params JsonObject[] mutations)
    {
        var body = new JsonObject
        {
            ["deviceId"] = deviceId.ToString(),
            ["mutations"] = new JsonArray(mutations.Select(m => (JsonNode)m.DeepClone()).ToArray()),
        }.ToJsonString();
        using var content = new StringContent(body, Encoding.UTF8, "application/json");
        using var response = await client.PostAsync(new Uri("/v1/sync/push", UriKind.Relative), content);
        var text = await response.Content.ReadAsStringAsync();
        response.StatusCode.ShouldBe(HttpStatusCode.OK, text);
        using var document = JsonDocument.Parse(text);
        foreach (var receipt in document.RootElement.GetProperty("results").EnumerateArray())
        {
            receipt.GetProperty("status").GetString().ShouldBe("applied", receipt.GetRawText());
        }
    }

    private static Guid Id(int n) => Guid.Parse(string.Create(CultureInfo.InvariantCulture, $"e1000000-0000-4000-8000-{n:D12}"));

    // ---- reads ----------------------------------------------------------------------------------------

    private static Task<HttpResponseMessage> GetAsync(HttpClient client, string? cursor = null, string? limit = null)
    {
        var query = new List<string>();
        if (cursor is not null)
        {
            query.Add($"cursor={Uri.EscapeDataString(cursor)}");
        }

        if (limit is not null)
        {
            query.Add($"limit={limit}");
        }

        return client.GetAsync(new Uri("/v1/sync/pull" + (query.Count == 0 ? string.Empty : "?" + string.Join('&', query)), UriKind.Relative));
    }

    private static async Task<Page> PullAsync(HttpClient client, string? cursor = null, int? limit = null)
    {
        using var response = await GetAsync(client, cursor, limit?.ToString(CultureInfo.InvariantCulture));
        var text = await response.Content.ReadAsStringAsync();
        response.StatusCode.ShouldBe(HttpStatusCode.OK, text);
        response.Content.Headers.ContentType?.MediaType.ShouldBe("application/json");
        response.Headers.CacheControl!.NoStore.ShouldBeTrue();
        using var document = JsonDocument.Parse(text);
        var root = document.RootElement;
        root.EnumerateObject().Select(p => p.Name).ShouldBe(["changes", "nextCursor", "hasMore"], ignoreOrder: true);
        return new Page(
            [.. root.GetProperty("changes").EnumerateArray().Select(c => c.Clone())],
            root.GetProperty("nextCursor").GetString()!,
            root.GetProperty("hasMore").GetBoolean());
    }

    /// <summary>Follows nextCursor until a page says there is nothing more.</summary>
    private static async Task<(List<JsonElement> Changes, string Cursor)> PullAllAsync(HttpClient client, string? cursor = null, int limit = 100)
    {
        var all = new List<JsonElement>();
        Page page;
        do
        {
            page = await PullAsync(client, cursor, limit);
            all.AddRange(page.Changes);
            cursor = page.NextCursor;
        }
        while (page.HasMore);

        return (all, cursor!);
    }

    private static string[] EntityIds(IEnumerable<JsonElement> changes) => [.. changes.Select(c => c.GetProperty("entityId").GetString()!)];

    private static async Task AssertProblemAsync(HttpResponseMessage response, HttpStatusCode status, string code)
    {
        var body = await response.Content.ReadAsStringAsync();
        response.StatusCode.ShouldBe(status, body);
        response.Content.Headers.ContentType?.MediaType.ShouldBe("application/problem+json");
        using var document = JsonDocument.Parse(body);
        document.RootElement.GetProperty("code").GetString().ShouldBe(code);
        document.RootElement.GetProperty("traceId").GetString().ShouldNotBeNullOrWhiteSpace();
    }

    // ---- request-level outcomes -----------------------------------------------------------------------

    [Fact]
    public async Task Pull_requires_authentication()
    {
        var setup = await SetupAsync("pull_auth");
        await using var factory = Factory(setup);
        using var anonymous = factory.CreateClient();

        using var response = await GetAsync(anonymous);

        response.StatusCode.ShouldBe(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task A_user_without_changes_gets_an_empty_page_and_a_stable_cursor()
    {
        var setup = await SetupAsync("pull_empty");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);

        var first = await PullAsync(client);
        var again = await PullAsync(client, first.NextCursor);

        first.Changes.ShouldBeEmpty();
        first.HasMore.ShouldBeFalse();
        first.NextCursor.ShouldNotBeNullOrWhiteSpace();
        again.Changes.ShouldBeEmpty();
        again.NextCursor.ShouldBe(first.NextCursor);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("101")]
    [InlineData("-1")]
    [InlineData("abc")]
    [InlineData("")]
    [InlineData("1.5")]
    public async Task A_limit_outside_1_to_100_is_400(string limit)
    {
        var setup = await SetupAsync("pull_limit");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);

        using var response = await GetAsync(client, limit: limit);

        await AssertProblemAsync(response, HttpStatusCode.BadRequest, "bad_request");
    }

    [Fact]
    public async Task Limit_bounds_are_accepted_and_the_default_page_is_100()
    {
        var setup = await SetupAsync("pull_bounds");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        await PushAsync(client, Guid.NewGuid(), Enumerable.Range(1, 100).Select(n => Upsert(Id(n), 70m)).ToArray());
        await PushAsync(client, Guid.NewGuid(), Upsert(Id(101), 70m));

        (await PullAsync(client, limit: 1)).Changes.Length.ShouldBe(1);
        var defaultPage = await PullAsync(client);

        defaultPage.Changes.Length.ShouldBe(100);
        defaultPage.HasMore.ShouldBeTrue();
        (await PullAsync(client, defaultPage.NextCursor)).Changes.Length.ShouldBe(1);
    }

    [Fact]
    public async Task A_repeated_or_empty_cursor_parameter_is_400()
    {
        var setup = await SetupAsync("pull_cursorparam");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var cursor = (await PullAsync(client)).NextCursor;

        foreach (var url in new[] { $"/v1/sync/pull?cursor={cursor}&cursor={cursor}", "/v1/sync/pull?cursor=" })
        {
            using var response = await client.GetAsync(new Uri(url, UriKind.Relative));
            await AssertProblemAsync(response, HttpStatusCode.BadRequest, "bad_request");
        }
    }

    [Fact]
    public async Task Pull_is_rate_limited_with_the_sync_policy()
    {
        var setup = await SetupAsync("pull_rate");
        await using var factory = Factory(setup, ("RateLimiting:Sync:PermitLimit", "2"));
        using var client = Client(factory, setup, setup.UserA);

        (await GetAsync(client)).StatusCode.ShouldBe(HttpStatusCode.OK);
        (await GetAsync(client)).StatusCode.ShouldBe(HttpStatusCode.OK);
        using var limited = await GetAsync(client);

        await AssertProblemAsync(limited, HttpStatusCode.TooManyRequests, "rate_limited");
        limited.Headers.RetryAfter.ShouldNotBeNull();
    }

    // ---- the feed -------------------------------------------------------------------------------------

    [Fact]
    public async Task Pushed_changes_come_back_in_order_with_their_versions_and_payloads()
    {
        var setup = await SetupAsync("pull_roundtrip");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var device = Guid.NewGuid();
        var (a, b) = (Id(1), Id(2));
        await PushAsync(client, device, Upsert(a, 72.35m), Upsert(b, 80m));
        await PushAsync(client, device, Upsert(a, 73.1m, baseVersion: 1));
        await PushAsync(client, device, Delete(b, baseVersion: 1));

        var (changes, _) = await PullAllAsync(client);

        changes.Count.ShouldBe(4);
        changes.Select(c => (c.GetProperty("entityId").GetString(), c.GetProperty("operation").GetString(), c.GetProperty("serverVersion").GetInt64()))
            .ShouldBe([(a.ToString(), "upsert", 1L), (b.ToString(), "upsert", 1L), (a.ToString(), "upsert", 2L), (b.ToString(), "delete", 2L)]);
        changes.ShouldAllBe(c => c.GetProperty("entityType").GetString() == "body_measurement");
        changes.Select(c => c.GetProperty("changeId").GetString()).Distinct().Count().ShouldBe(4);

        var first = changes[0].GetProperty("payload");
        first.GetProperty("id").GetString().ShouldBe(a.ToString());
        first.GetProperty("kind").GetString().ShouldBe("weight");
        first.GetProperty("value").GetDecimal().ShouldBe(72.35m);
        changes[2].GetProperty("payload").GetProperty("value").GetDecimal().ShouldBe(73.1m);

        var tombstone = changes[3].GetProperty("payload");
        tombstone.EnumerateObject().Select(p => p.Name).ShouldBe(["id", "deletedAt"], ignoreOrder: true);
        tombstone.GetProperty("id").GetString().ShouldBe(b.ToString());
    }

    [Fact]
    public async Task Plans_created_over_http_appear_in_the_feed()
    {
        var setup = await SetupAsync("pull_plans");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var plan = new JsonObject
        {
            ["id"] = Guid.NewGuid(),
            ["title"] = "Push day",
            ["workouts"] = new JsonArray(new JsonObject
            {
                ["id"] = Guid.NewGuid(), ["weekday"] = 1, ["orderIndex"] = 0,
                ["exercises"] = new JsonArray(new JsonObject
                {
                    ["id"] = Guid.NewGuid(), ["exerciseId"] = TuckPlanche, ["orderIndex"] = 0, ["setCount"] = 3,
                    ["target"] = new JsonObject { ["kind"] = "static_hold", ["holdSeconds"] = 12 }, ["restSeconds"] = 90,
                }),
            }),
        };
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri("/v1/plans", UriKind.Relative))
        {
            Content = new StringContent(plan.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        request.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString());
        using var created = await client.SendAsync(request);
        created.StatusCode.ShouldBe(HttpStatusCode.Created, await created.Content.ReadAsStringAsync());

        var (changes, _) = await PullAllAsync(client);

        changes.Select(c => c.GetProperty("entityType").GetString()).ShouldBe(["training_plan", "planned_workout", "planned_exercise"], ignoreOrder: true);
        changes.ShouldAllBe(c => c.GetProperty("operation").GetString() == "upsert" && c.GetProperty("serverVersion").GetInt64() == 1);
        changes.Single(c => c.GetProperty("entityType").GetString() == "training_plan").GetProperty("payload").GetProperty("title").GetString()
            .ShouldBe("Push day");
    }

    [Fact]
    public async Task Pages_walk_the_feed_once_in_order_and_a_new_push_shows_up_alone()
    {
        var setup = await SetupAsync("pull_pages");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var device = Guid.NewGuid();
        var ids = Enumerable.Range(1, 25).Select(Id).ToArray();
        await PushAsync(client, device, ids.Take(10).Select(id => Upsert(id, 70m)).ToArray());
        await PushAsync(client, device, ids.Skip(10).Select(id => Upsert(id, 70m)).ToArray());

        var sizes = new List<int>();
        var seen = new List<JsonElement>();
        string? cursor = null;
        Page page;
        do
        {
            page = await PullAsync(client, cursor, 10);
            sizes.Add(page.Changes.Length);
            seen.AddRange(page.Changes);
            cursor = page.NextCursor;
        }
        while (page.HasMore);

        sizes.ShouldBe([10, 10, 5]);
        EntityIds(seen).ShouldBe(ids.Select(id => id.ToString()));
        (await PullAsync(client, cursor)).Changes.ShouldBeEmpty();

        await PushAsync(client, device, Upsert(Id(26), 71m));
        var incremental = await PullAsync(client, cursor);

        EntityIds(incremental.Changes).ShouldBe([Id(26).ToString()]);
    }

    [Fact]
    public async Task A_change_id_resumes_right_after_that_change()
    {
        var setup = await SetupAsync("pull_changeid");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        await PushAsync(client, Guid.NewGuid(), Enumerable.Range(1, 5).Select(n => Upsert(Id(n), 70m)).ToArray());
        var (changes, last) = await PullAllAsync(client);

        var fromThird = await PullAsync(client, changes[2].GetProperty("changeId").GetString());
        var fromLast = await PullAsync(client, changes[^1].GetProperty("changeId").GetString());

        EntityIds(fromThird.Changes).ShouldBe([Id(4).ToString(), Id(5).ToString()]);
        fromLast.Changes.ShouldBeEmpty();
        fromLast.NextCursor.ShouldBe(last);
    }

    [Fact]
    public async Task Changes_pushed_between_two_pages_are_neither_skipped_nor_repeated()
    {
        var setup = await SetupAsync("pull_between");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var device = Guid.NewGuid();
        await PushAsync(client, device, Enumerable.Range(1, 12).Select(n => Upsert(Id(n), 70m)).ToArray());

        var first = await PullAsync(client, limit: 5);
        await PushAsync(client, device, Enumerable.Range(13, 8).Select(n => Upsert(Id(n), 70m)).ToArray());
        var (rest, _) = await PullAllAsync(client, first.NextCursor, 5);

        EntityIds([.. first.Changes, .. rest]).ShouldBe(Enumerable.Range(1, 20).Select(n => Id(n).ToString()));
    }

    [Fact]
    public async Task Concurrent_pushers_never_make_a_puller_skip_or_repeat_a_change()
    {
        var setup = await SetupAsync("pull_concurrent");
        await using var factory = Factory(setup);
        using var puller = Client(factory, setup, setup.UserA);
        var pushed = new System.Collections.Concurrent.ConcurrentBag<Guid>();

        // 3 devices of the same user, each sending 6 pushes of 3 mutations while the puller keeps walking.
        var pushers = Enumerable.Range(0, 3).Select(device => Task.Run(async () =>
        {
            using var client = Client(factory, setup, setup.UserA);
            var deviceId = Guid.NewGuid();
            for (var batch = 0; batch < 6; batch++)
            {
                var ids = Enumerable.Range(0, 3).Select(i => Id((device * 100) + (batch * 3) + i + 1)).ToArray();
                await PushAsync(client, deviceId, ids.Select(id => Upsert(id, 70m)).ToArray());
                foreach (var id in ids)
                {
                    pushed.Add(id);
                }
            }
        })).ToArray();

        var seen = new List<JsonElement>();
        string? cursor = null;
        while (!pushers.All(t => t.IsCompleted))
        {
            var page = await PullAsync(puller, cursor, 7);
            seen.AddRange(page.Changes);
            cursor = page.NextCursor;
            if (page.Changes.Length == 0)
            {
                await Task.Delay(5);
            }
        }

        await Task.WhenAll(pushers);
        var (tail, _) = await PullAllAsync(puller, cursor, 7);
        seen.AddRange(tail);

        var seenIds = EntityIds(seen);
        seenIds.Length.ShouldBe(54);
        seenIds.Distinct().Count().ShouldBe(54);
        seenIds.ShouldBe(pushed.Select(id => id.ToString()), ignoreOrder: true);
        (await ScalarAsync<long>(setup.ConnectionString, "SELECT count(*) FROM sync_change_log")).ShouldBe(54);

        // One push is one transaction, so its three changes are adjacent and in request order.
        foreach (var device in Enumerable.Range(0, 3))
        {
            for (var batch = 0; batch < 6; batch++)
            {
                var start = Array.IndexOf(seenIds, Id((device * 100) + (batch * 3) + 1).ToString());
                seenIds.Skip(start).Take(3).ShouldBe(Enumerable.Range(0, 3).Select(i => Id((device * 100) + (batch * 3) + i + 1).ToString()));
            }
        }
    }

    // ---- isolation and cursor integrity ---------------------------------------------------------------

    [Fact]
    public async Task A_user_only_sees_their_own_changes()
    {
        var setup = await SetupAsync("pull_idor");
        await using var factory = Factory(setup);
        using var userA = Client(factory, setup, setup.UserA);
        using var userB = Client(factory, setup, setup.UserB);
        await PushAsync(userA, Guid.NewGuid(), Upsert(Id(1), 70m), Upsert(Id(2), 71m));
        await PushAsync(userB, Guid.NewGuid(), Upsert(Id(3), 90m));

        EntityIds((await PullAllAsync(userA)).Changes).ShouldBe([Id(1).ToString(), Id(2).ToString()]);
        EntityIds((await PullAllAsync(userB)).Changes).ShouldBe([Id(3).ToString()]);
    }

    [Fact]
    public async Task Another_users_cursor_and_change_id_are_rejected_and_reveal_nothing()
    {
        var setup = await SetupAsync("pull_idor_cursor");
        await using var factory = Factory(setup);
        using var userA = Client(factory, setup, setup.UserA);
        using var userB = Client(factory, setup, setup.UserB);
        await PushAsync(userA, Guid.NewGuid(), Upsert(Id(1), 70m), Upsert(Id(2), 71m));
        var (changes, cursorA) = await PullAllAsync(userA);

        foreach (var token in new[] { cursorA, changes[0].GetProperty("changeId").GetString()! })
        {
            using var response = await GetAsync(userB, token);
            await AssertProblemAsync(response, HttpStatusCode.BadRequest, "bad_request");
        }
    }

    [Theory]
    [InlineData("garbage")]
    [InlineData("AAAA")]
    [InlineData("12345")]
    [InlineData("!!!!")]
    [InlineData("%00")]
    public async Task A_cursor_that_this_server_did_not_issue_is_400(string cursor)
    {
        var setup = await SetupAsync("pull_badcursor");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);

        using var response = await GetAsync(client, cursor);

        await AssertProblemAsync(response, HttpStatusCode.BadRequest, "bad_request");
    }

    [Fact]
    public async Task An_altered_cursor_is_400_and_never_skips_changes()
    {
        var setup = await SetupAsync("pull_tamper");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        await PushAsync(client, Guid.NewGuid(), Enumerable.Range(1, 5).Select(n => Upsert(Id(n), 70m)).ToArray());
        var first = await PullAsync(client, limit: 2);

        var altered = string.Concat(first.NextCursor.AsSpan(0, 5), first.NextCursor[5] == 'A' ? "B" : "A", first.NextCursor.AsSpan(6));
        using var response = await GetAsync(client, altered);

        await AssertProblemAsync(response, HttpStatusCode.BadRequest, "bad_request");
    }

    [Fact]
    public async Task A_cursor_is_only_valid_under_the_key_that_signed_it()
    {
        var setup = await SetupAsync("pull_key");
        var keyOne = Convert.ToBase64String(new byte[32].Select((_, i) => (byte)(i + 1)).ToArray());
        var keyTwo = Convert.ToBase64String(new byte[32].Select((_, i) => (byte)(i + 50)).ToArray());
        string cursor;
        await using (var one = Factory(setup, ("Sync:CursorSigningKey", keyOne)))
        using (var client = Client(one, setup, setup.UserA))
        {
            await PushAsync(client, Guid.NewGuid(), Upsert(Id(1), 70m));
            cursor = (await PullAsync(client)).NextCursor;
            (await PullAsync(client, cursor)).Changes.ShouldBeEmpty();
        }

        await using var two = Factory(setup, ("Sync:CursorSigningKey", keyTwo));
        using var other = Client(two, setup, setup.UserA);
        using var response = await GetAsync(other, cursor);

        await AssertProblemAsync(response, HttpStatusCode.BadRequest, "bad_request");
    }

    // ---- retention and full resync --------------------------------------------------------------------

    [Fact]
    public async Task A_cursor_older_than_the_retention_window_is_410_and_a_fresh_pull_still_works()
    {
        var setup = await SetupAsync("pull_expired");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        await PushAsync(client, Guid.NewGuid(), Upsert(Id(1), 70m), Upsert(Id(2), 71m));
        var (changes, cursor) = await PullAllAsync(client);
        await PushAsync(client, Guid.NewGuid(), Upsert(Id(3), 72m));

        await ExecuteAsync(setup.ConnectionString, "UPDATE sync_change_log SET changed_at = now() - interval '181 days' WHERE seq <= 2");

        using var expired = await GetAsync(client, cursor);
        using var expiredChangeId = await GetAsync(client, changes[0].GetProperty("changeId").GetString());
        await AssertProblemAsync(expired, HttpStatusCode.Gone, "cursor_expired");
        await AssertProblemAsync(expiredChangeId, HttpStatusCode.Gone, "cursor_expired");

        // Full resync: no cursor, and the new cursor works again.
        var (resynced, fresh) = await PullAllAsync(client);
        EntityIds(resynced).ShouldBe([Id(1).ToString(), Id(2).ToString(), Id(3).ToString()]);
        (await PullAsync(client, fresh)).Changes.ShouldBeEmpty();
    }

    [Fact]
    public async Task A_cursor_just_inside_the_retention_window_still_works()
    {
        var setup = await SetupAsync("pull_window");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        await PushAsync(client, Guid.NewGuid(), Upsert(Id(1), 70m));
        var (_, cursor) = await PullAllAsync(client);
        await PushAsync(client, Guid.NewGuid(), Upsert(Id(2), 71m));
        await ExecuteAsync(setup.ConnectionString, "UPDATE sync_change_log SET changed_at = now() - interval '179 days' WHERE seq = 1");

        EntityIds((await PullAsync(client, cursor)).Changes).ShouldBe([Id(2).ToString()]);
    }

    [Fact]
    public async Task The_retention_window_is_configurable()
    {
        var setup = await SetupAsync("pull_retention");
        await using var factory = Factory(setup, ("Sync:ChangeLogRetentionDays", "30"));
        using var client = Client(factory, setup, setup.UserA);
        await PushAsync(client, Guid.NewGuid(), Upsert(Id(1), 70m));
        var (_, cursor) = await PullAllAsync(client);
        await ExecuteAsync(setup.ConnectionString, "UPDATE sync_change_log SET changed_at = now() - interval '31 days'");

        using var response = await GetAsync(client, cursor);

        await AssertProblemAsync(response, HttpStatusCode.Gone, "cursor_expired");
    }

    [Fact]
    public async Task A_full_resync_after_compaction_returns_the_latest_state_and_old_cursors_are_410()
    {
        var setup = await SetupAsync("pull_compaction");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        var device = Guid.NewGuid();
        await PushAsync(client, device, Upsert(Id(1), 70m), Upsert(Id(2), 80m));
        var (beforeUpdate, cursorAfterV1) = await PullAllAsync(client);
        var cursorAtV1OfEntity1 = beforeUpdate[0].GetProperty("changeId").GetString();
        await PushAsync(client, device, Upsert(Id(1), 71m, baseVersion: 1));

        // What a retention job does: drop the superseded v1 row once it is past the window.
        await ExecuteAsync(setup.ConnectionString, "UPDATE sync_change_log SET changed_at = now() - interval '200 days' WHERE seq = 1");
        await ExecuteAsync(setup.ConnectionString, "DELETE FROM sync_change_log WHERE seq = 1");

        // A cursor at the surviving seq 2 is still inside the window and keeps working.
        EntityIds((await PullAsync(client, cursorAfterV1)).Changes).ShouldBe([Id(1).ToString()]);

        // A cursor at the removed seq 1 can no longer prove nothing was missed: full resync.
        using var gone = await GetAsync(client, cursorAtV1OfEntity1);
        await AssertProblemAsync(gone, HttpStatusCode.Gone, "cursor_expired");

        var (resynced, _) = await PullAllAsync(client);
        EntityIds(resynced).ShouldBe([Id(2).ToString(), Id(1).ToString()]);
        resynced.Select(c => c.GetProperty("serverVersion").GetInt64()).ShouldBe([1L, 2L]);
    }

    [Fact]
    public async Task A_cursor_ahead_of_the_feed_is_410()
    {
        var setup = await SetupAsync("pull_ahead");
        await using var factory = Factory(setup);
        using var client = Client(factory, setup, setup.UserA);
        await PushAsync(client, Guid.NewGuid(), Upsert(Id(1), 70m), Upsert(Id(2), 71m));
        var (_, cursor) = await PullAllAsync(client);

        // The feed was restored from an older backup: seq 2 no longer exists.
        await ExecuteAsync(setup.ConnectionString, "DELETE FROM sync_change_log WHERE seq = 2");
        await ExecuteAsync(setup.ConnectionString, "UPDATE user_sync_state SET last_seq = 1");

        using var response = await GetAsync(client, cursor);

        await AssertProblemAsync(response, HttpStatusCode.Gone, "cursor_expired");
    }

    // ---- configuration --------------------------------------------------------------------------------

    private static IConfiguration Config(params (string Key, string? Value)[] values) =>
        new ConfigurationBuilder().AddInMemoryCollection(values.ToDictionary(v => v.Key, v => v.Value)).Build();

    private static HostingEnvironment Env(string name) => new() { EnvironmentName = name };

    [Fact]
    public void The_cursor_key_comes_from_configuration()
    {
        var key = new byte[32].Select((_, i) => (byte)(i + 3)).ToArray();

        SyncPullSetup.ResolveKey(Config((SyncPullSetup.CursorKeyConfigKey, Convert.ToBase64String(key))), Env("Production"), NullLogger.Instance)
            .ShouldBe(key);
    }

    [Theory]
    [InlineData("not base64!")]
    [InlineData("AAAA")]
    public void A_malformed_or_short_cursor_key_is_a_configuration_error(string value)
    {
        Should.Throw<InvalidOperationException>(
            () => SyncPullSetup.ResolveKey(Config((SyncPullSetup.CursorKeyConfigKey, value)), Env("Development"), NullLogger.Instance))
            .Message.ShouldNotContain(value);
    }

    [Fact]
    public void Outside_development_a_missing_cursor_key_is_a_configuration_error()
    {
        Should.Throw<InvalidOperationException>(
            () => SyncPullSetup.ResolveKey(Config(), Env("Production"), NullLogger.Instance));
        Should.Throw<InvalidOperationException>(
            () => SyncPullSetup.ResolveKey(Config((DevTokenDefaults.SigningKeyConfigKey, DevSigningKey.Generate())), Env("Production"), NullLogger.Instance));
    }

    [Fact]
    public void Development_derives_a_stable_cursor_key_from_the_dev_token_key()
    {
        var devKey = DevSigningKey.Generate();
        var config = Config((DevTokenDefaults.SigningKeyConfigKey, devKey));

        var first = SyncPullSetup.ResolveKey(config, Env("Development"), NullLogger.Instance);
        var second = SyncPullSetup.ResolveKey(config, Env("Development"), NullLogger.Instance);

        first.ShouldBe(second);
        first.Length.ShouldBe(32);
        first.ShouldNotBe(Convert.FromBase64String(devKey));
    }

    [Fact]
    public void Development_without_any_key_falls_back_to_a_random_per_process_key()
    {
        var one = SyncPullSetup.ResolveKey(Config(), Env("Development"), NullLogger.Instance);
        var two = SyncPullSetup.ResolveKey(Config(), Env("Development"), NullLogger.Instance);

        one.Length.ShouldBe(32);
        one.ShouldNotBe(two);
    }

    [Fact]
    public void Retention_defaults_to_180_days_and_rejects_nonsense()
    {
        SyncPullSetup.ResolveRetention(Config()).ShouldBe(TimeSpan.FromDays(180));
        SyncPullSetup.ResolveRetention(Config((SyncPullSetup.RetentionConfigKey, "30"))).ShouldBe(TimeSpan.FromDays(30));
        foreach (var bad in new[] { "0", "-5", "abc", "1.5" })
        {
            Should.Throw<InvalidOperationException>(() => SyncPullSetup.ResolveRetention(Config((SyncPullSetup.RetentionConfigKey, bad))));
        }
    }

    // ---- db helpers -----------------------------------------------------------------------------------

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
