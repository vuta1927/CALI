using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using Cali.IntegrationTests.Infrastructure;
using Npgsql;

namespace Cali.IntegrationTests;

/// <summary>B1 (BE-001/002): GET /v1/exercises, /v1/exercises/{id}, /v1/criteria-config.</summary>
[Collection(PostgresCollection.Name)]
public sealed class CatalogEndpointTests(PostgresFixture postgres)
{
    private static CaliApiFactory Factory(string connectionString, int? publicPermitLimit = null)
    {
        var settings = new Dictionary<string, string?> { ["ConnectionStrings:Cali"] = connectionString };
        if (publicPermitLimit is { } limit)
        {
            settings["RateLimiting:Public:PermitLimit"] = limit.ToString(System.Globalization.CultureInfo.InvariantCulture);
            settings["RateLimiting:Public:WindowSeconds"] = "60";
        }

        return new CaliApiFactory("Development", settings);
    }

    internal static async Task ExecuteAsync(string connectionString, string sql, params object?[] args)
    {
        await using var dataSource = NpgsqlDataSource.Create(connectionString);
        await using var command = dataSource.CreateCommand(sql);
        foreach (var arg in args)
        {
            command.Parameters.AddWithValue(arg ?? DBNull.Value);
        }

        await command.ExecuteNonQueryAsync();
    }

    internal static async Task<Guid> InsertExerciseAsync(
        string connectionString, string slug, string name, string type = "reps", bool published = true,
        string equipment = "[]", string focusTags = "[]")
    {
        var id = Guid.NewGuid();
        await ExecuteAsync(connectionString, """
            INSERT INTO exercise_catalog (id, slug, name, exercise_type, equipment, cues, focus_tags, is_published)
            VALUES ($1, $2, $3, $4, $5::jsonb, '["Keep a hollow body"]'::jsonb, $6::jsonb, $7)
            """, id, slug, name, type, equipment, focusTags, published);
        return id;
    }

    private static async Task<JsonElement> GetJsonAsync(HttpClient client, string url, HttpStatusCode expected = HttpStatusCode.OK)
    {
        var response = await client.GetAsync(new Uri(url, UriKind.Relative));
        var body = await response.Content.ReadAsStringAsync();
        response.StatusCode.ShouldBe(expected, body);
        using var document = JsonDocument.Parse(body);
        return document.RootElement.Clone();
    }

    private static async Task AssertProblemAsync(HttpResponseMessage response, HttpStatusCode status, string code)
    {
        response.StatusCode.ShouldBe(status);
        response.Content.Headers.ContentType?.MediaType.ShouldBe("application/problem+json");
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        document.RootElement.GetProperty("code").GetString().ShouldBe(code);
        document.RootElement.GetProperty("traceId").GetString().ShouldNotBeNullOrWhiteSpace();
    }

    private static string[] Slugs(JsonElement page) =>
        page.GetProperty("items").EnumerateArray().Select(e => e.GetProperty("slug").GetString()!).ToArray();

    [Fact]
    public async Task Exercises_are_anonymous_and_hide_unpublished_rows()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("cat_publish");
        var visible = await InsertExerciseAsync(cs, "ex-hollow-hold", "Hollow hold", "static_hold");
        var hidden = await InsertExerciseAsync(cs, "ex-draft", "Draft", published: false);
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        var page = await GetJsonAsync(client, "/v1/exercises");

        Slugs(page).ShouldBe(["ex-hollow-hold"]);
        page.GetProperty("hasMore").GetBoolean().ShouldBeFalse();
        page.GetProperty("nextCursor").ValueKind.ShouldBe(JsonValueKind.Null);

        var exercise = await GetJsonAsync(client, $"/v1/exercises/{visible}");
        exercise.GetProperty("measurementType").GetString().ShouldBe("hold");
        exercise.GetProperty("discipline").GetString().ShouldBe("calisthenics");
        exercise.GetProperty("cues")[0].GetString().ShouldBe("Keep a hollow body");

        await AssertProblemAsync(await client.GetAsync(new Uri($"/v1/exercises/{hidden}", UriKind.Relative)),
            HttpStatusCode.NotFound, "not_found");
        await AssertProblemAsync(await client.GetAsync(new Uri($"/v1/exercises/{Guid.NewGuid()}", UriKind.Relative)),
            HttpStatusCode.NotFound, "not_found");
    }

    [Fact]
    public async Task Cursor_pagination_is_stable_when_rows_are_inserted_mid_way()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("cat_page");
        foreach (var slug in new[] { "ex-b", "ex-d", "ex-f", "ex-h", "ex-j" })
        {
            await InsertExerciseAsync(cs, slug, slug);
        }

        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        var first = await GetJsonAsync(client, "/v1/exercises?limit=2");
        Slugs(first).ShouldBe(["ex-b", "ex-d"]);
        first.GetProperty("hasMore").GetBoolean().ShouldBeTrue();
        var cursor = first.GetProperty("nextCursor").GetString()!;

        // One row sorts before the cursor (already passed), one after it (still ahead).
        await InsertExerciseAsync(cs, "ex-a", "ex-a");
        await InsertExerciseAsync(cs, "ex-e", "ex-e");

        var seen = new List<string>(Slugs(first));
        while (cursor is not null)
        {
            var page = await GetJsonAsync(client, $"/v1/exercises?limit=2&cursor={Uri.EscapeDataString(cursor)}");
            seen.AddRange(Slugs(page));
            cursor = page.GetProperty("hasMore").GetBoolean() ? page.GetProperty("nextCursor").GetString() : null;
        }

        seen.ShouldBe(["ex-b", "ex-d", "ex-e", "ex-f", "ex-h", "ex-j"]);
    }

    [Fact]
    public async Task Filters_match_type_equipment_and_literal_query_text()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("cat_filter");
        await InsertExerciseAsync(cs, "ex-pull-up", "Pull-up", "reps", equipment: """["pull_up_bar"]""");
        await InsertExerciseAsync(cs, "ex-l-sit", "L-sit 100% hold", "static_hold", equipment: """["parallettes"]""");
        await InsertExerciseAsync(cs, "ex-push-up", "Push-up", "reps");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        Slugs(await GetJsonAsync(client, "/v1/exercises?type=static_hold")).ShouldBe(["ex-l-sit"]);
        Slugs(await GetJsonAsync(client, "/v1/exercises?equipment=pull_up_bar")).ShouldBe(["ex-pull-up"]);
        Slugs(await GetJsonAsync(client, "/v1/exercises?q=PUSH")).ShouldBe(["ex-push-up"]);
        Slugs(await GetJsonAsync(client, "/v1/exercises?q=pull-up")).ShouldBe(["ex-pull-up"]);
        // LIKE metacharacters are literal: '%' only matches the name that contains it.
        Slugs(await GetJsonAsync(client, "/v1/exercises?q=%25")).ShouldBe(["ex-l-sit"]);
        Slugs(await GetJsonAsync(client, "/v1/exercises?q=_")).ShouldBeEmpty();
        Slugs(await GetJsonAsync(client, "/v1/exercises?type=reps&q=up")).ShouldBe(["ex-pull-up", "ex-push-up"]);
    }

    [Theory]
    [InlineData("limit=0")]
    [InlineData("limit=101")]
    [InlineData("limit=abc")]
    [InlineData("limit=-1")]
    [InlineData("limit=1&limit=2")]
    [InlineData("cursor=not-a-cursor")]
    [InlineData("cursor=WyJleC1hIl0")] // base64url of ["ex-a"]: wrong arity
    [InlineData("type=bogus")]
    [InlineData("equipment=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
    public async Task Invalid_list_parameters_return_400(string query)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("cat_bad");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        await AssertProblemAsync(await client.GetAsync(new Uri($"/v1/exercises?{query}", UriKind.Relative)),
            HttpStatusCode.BadRequest, "bad_request");
    }

    [Fact]
    public async Task Query_longer_than_100_characters_returns_400()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("cat_q");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        await AssertProblemAsync(await client.GetAsync(new Uri($"/v1/exercises?q={new string('a', 101)}", UriKind.Relative)),
            HttpStatusCode.BadRequest, "bad_request");
        (await client.GetAsync(new Uri($"/v1/exercises?q={new string('a', 100)}", UriKind.Relative))).StatusCode.ShouldBe(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Exercise_media_lists_only_public_reviewed_newest_versions_without_storage_keys()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("cat_media");
        var id = await InsertExerciseAsync(cs, "ex-tuck-planche", "Tuck planche", "static_hold");
        const string media = """
            INSERT INTO exercise_media (id, exercise_id, kind, content_version, storage_key, mime_type, sha256, size_bytes, license, is_public, reviewed_at)
            VALUES ($1, $2, $3, $4, $5, 'image/webp', $6, 1024, 'CC-BY-4.0', $7, CASE WHEN $8 THEN now() END)
            """;
        var newest = Guid.NewGuid();
        await ExecuteAsync(cs, media, Guid.NewGuid(), id, "thumbnail", 1, "internal/thumb-v1", new string('a', 64), true, true);
        await ExecuteAsync(cs, media, newest, id, "thumbnail", 2, "internal/thumb-v2", new string('b', 64), true, true);
        await ExecuteAsync(cs, media, Guid.NewGuid(), id, "poster", 1, "internal/poster-private", new string('c', 64), false, true);
        await ExecuteAsync(cs, media, Guid.NewGuid(), id, "preview", 1, "internal/preview-unreviewed", new string('d', 64), true, false);
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        var response = await client.GetAsync(new Uri($"/v1/exercises/{id}", UriKind.Relative));
        var raw = await response.Content.ReadAsStringAsync();
        using var document = JsonDocument.Parse(raw);
        var items = document.RootElement.GetProperty("media").EnumerateArray().ToArray();

        items.Length.ShouldBe(1);
        items[0].GetProperty("id").GetGuid().ShouldBe(newest);
        items[0].GetProperty("contentVersion").GetInt32().ShouldBe(2);
        items[0].GetProperty("sha256").GetString().ShouldBe(new string('b', 64));
        items[0].GetProperty("url").ValueKind.ShouldBe(JsonValueKind.Null);
        raw.ShouldNotContain("internal/");
    }

    [Fact]
    public async Task Criteria_config_returns_latest_version_with_etag_and_cache_headers()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("crit_ok");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        var response = await client.GetAsync(new Uri("/v1/criteria-config", UriKind.Relative));

        response.StatusCode.ShouldBe(HttpStatusCode.OK);
        // db/005 seeds 6 indicator rows at version 1 -> set version 6.
        response.Headers.ETag!.Tag.ShouldBe("\"c1.i6\"");
        response.Headers.ETag.IsWeak.ShouldBeFalse();
        response.Headers.CacheControl!.Public.ShouldBeTrue();
        response.Headers.CacheControl.MaxAge.ShouldBe(TimeSpan.FromSeconds(300));
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        var root = document.RootElement;
        root.GetProperty("version").GetInt32().ShouldBe(1);
        root.GetProperty("publishedAt").GetDateTimeOffset().ShouldBe(DateTimeOffset.Parse("2026-11-09T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture));
        root.GetProperty("supportedTypes").GetArrayLength().ShouldBe(5);
        root.GetProperty("criteria").GetArrayLength().ShouldBeGreaterThan(0);
        root.EnumerateObject().Select(p => p.Name).ShouldBe(["version", "publishedAt", "supportedTypes", "criteria", "indicators"], ignoreOrder: true);
        var indicators = root.GetProperty("indicators");
        indicators.GetProperty("version").GetInt32().ShouldBe(6);
        indicators.GetProperty("indicators").GetArrayLength().ShouldBe(6);
    }

    [Theory]
    [InlineData("\"c1.i6\"")]
    [InlineData("W/\"c1.i6\"")]
    [InlineData("\"c0.i1\", \"c1.i6\"")]
    [InlineData("*")]
    public async Task Matching_if_none_match_returns_304_without_body(string ifNoneMatch)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("crit_304");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri("/v1/criteria-config", UriKind.Relative));
        request.Headers.TryAddWithoutValidation("If-None-Match", ifNoneMatch).ShouldBeTrue();

        var response = await client.SendAsync(request);

        response.StatusCode.ShouldBe(HttpStatusCode.NotModified);
        response.Headers.ETag!.Tag.ShouldBe("\"c1.i6\"");
        (await response.Content.ReadAsByteArrayAsync()).ShouldBeEmpty();
    }

    [Fact]
    public async Task Stale_etag_returns_200_and_a_new_version_or_indicator_change_changes_the_etag()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("crit_etag");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        async Task<HttpResponseMessage> GetAsync(string url, string? etag)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(url, UriKind.Relative));
            if (etag is not null)
            {
                request.Headers.IfNoneMatch.Add(new EntityTagHeaderValue(etag));
            }

            return await client.SendAsync(request);
        }

        await ExecuteAsync(cs, """
            INSERT INTO criteria_config_versions (version, published_at, document)
            VALUES (2, '2026-11-10T00:00:00Z', '{"supportedTypes":["number"],"criteria":[]}'::jsonb)
            """);
        var latest = await GetAsync("/v1/criteria-config", "\"c1.i6\"");
        latest.StatusCode.ShouldBe(HttpStatusCode.OK);
        latest.Headers.ETag!.Tag.ShouldBe("\"c2.i6\"");

        // History stays readable under its own version.
        var v1 = await GetAsync("/v1/criteria-config?version=1", null);
        v1.StatusCode.ShouldBe(HttpStatusCode.OK);
        v1.Headers.ETag!.Tag.ShouldBe("\"c1.i6\"");

        // An indicator edit bumps its row version (db/005 guard) and so the set version.
        await ExecuteAsync(cs, "UPDATE indicator_definitions SET label = 'Best hold (s)' WHERE id = 'best_hold_seconds'");
        var afterEdit = await GetAsync("/v1/criteria-config", "\"c2.i6\"");
        afterEdit.StatusCode.ShouldBe(HttpStatusCode.OK);
        afterEdit.Headers.ETag!.Tag.ShouldBe("\"c2.i7\"");
    }

    [Fact]
    public async Task Unknown_criteria_version_returns_404_with_specific_code()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("crit_404");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        await AssertProblemAsync(await client.GetAsync(new Uri("/v1/criteria-config?version=99", UriKind.Relative)),
            HttpStatusCode.NotFound, "criteria_version_not_found");
    }

    [Theory]
    [InlineData("version=0")]
    [InlineData("version=abc")]
    [InlineData("version=1.5")]
    [InlineData("version=")]
    [InlineData("version=1&version=2")]
    public async Task Invalid_criteria_version_returns_400(string query)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("crit_bad");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();

        await AssertProblemAsync(await client.GetAsync(new Uri($"/v1/criteria-config?{query}", UriKind.Relative)),
            HttpStatusCode.BadRequest, "bad_request");
    }

    [Fact]
    public async Task Oversized_if_none_match_returns_400()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("crit_inm");
        await using var factory = Factory(cs);
        using var client = factory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri("/v1/criteria-config", UriKind.Relative));
        request.Headers.TryAddWithoutValidation("If-None-Match", $"\"{new string('x', 200)}\"").ShouldBeTrue();

        await AssertProblemAsync(await client.SendAsync(request), HttpStatusCode.BadRequest, "bad_request");
    }

    [Fact]
    public async Task Public_endpoints_are_rate_limited_per_client_with_retry_after()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("crit_429");
        await using var factory = Factory(cs, publicPermitLimit: 2);
        using var client = factory.CreateClient();

        (await client.GetAsync(new Uri("/v1/criteria-config", UriKind.Relative))).StatusCode.ShouldBe(HttpStatusCode.OK);
        (await client.GetAsync(new Uri("/v1/exercises", UriKind.Relative))).StatusCode.ShouldBe(HttpStatusCode.OK);
        var limited = await client.GetAsync(new Uri("/v1/criteria-config", UriKind.Relative));

        await AssertProblemAsync(limited, HttpStatusCode.TooManyRequests, "rate_limited");
        limited.Headers.RetryAfter.ShouldNotBeNull();
        limited.Headers.RetryAfter!.Delta!.Value.TotalSeconds.ShouldBeGreaterThanOrEqualTo(1);
    }
}
