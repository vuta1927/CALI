using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Cali.Application.Identity;
using Cali.Infrastructure.Auth;
using Cali.IntegrationTests.Infrastructure;
using Cali.Tests.Shared;
using Npgsql;

namespace Cali.IntegrationTests;

/// <summary>
/// B4 (BE-005, ADR-071): POST /v1/auth/apple and POST /v1/auth/refresh against PostgreSQL. Apple's keys are a fake;
/// every identity token is signed by a throw-away RSA key the test publishes through that fake.
/// </summary>
[Collection(PostgresCollection.Name)]
public sealed class AuthSessionTests(PostgresFixture postgres)
{
    private static readonly Uri AppleUri = new("/v1/auth/apple", UriKind.Relative);
    private static readonly Uri RefreshUri = new("/v1/auth/refresh", UriKind.Relative);
    private static readonly Uri MeUri = new("/v1/me", UriKind.Relative);

    private sealed class Host(AuthApiFactory factory, HttpClient client, AppleTestKey key, FakeAppleKeySetProvider keys, string connectionString)
        : IAsyncDisposable
    {
        public AuthApiFactory Factory { get; } = factory;

        public HttpClient Client { get; } = client;

        public AppleTestKey Key { get; } = key;

        public FakeAppleKeySetProvider Keys { get; } = keys;

        public string ConnectionString { get; } = connectionString;

        public async ValueTask DisposeAsync()
        {
            Client.Dispose();
            await Factory.DisposeAsync();
            Key.Dispose();
        }
    }

    private async Task<Host> StartAsync(string prefix, string environment = "Development", params (string Key, string? Value)[] settings)
    {
        var connectionString = await postgres.CreateMigratedDatabaseAsync(prefix);
        var key = AppleTestKey.Create();
        var keys = new FakeAppleKeySetProvider(key);
        var all = new Dictionary<string, string?> { ["ConnectionStrings:Cali"] = connectionString };
        foreach (var (k, v) in settings)
        {
            all[k] = v;
        }

        var factory = new AuthApiFactory(environment, all, keys);
        return new Host(factory, factory.CreateClient(), key, keys, connectionString);
    }

    private sealed class FixedTimeProvider(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }

    /// <summary>For requests that are refused before any database access (bad bodies, bad tokens): no database is created.</summary>
    private static Host StartWithoutDatabase()
    {
        var key = AppleTestKey.Create();
        var keys = new FakeAppleKeySetProvider(key);
        var factory = new AuthApiFactory(
            "Development",
            new Dictionary<string, string?> { ["ConnectionStrings:Cali"] = "Host=127.0.0.1;Port=1;Database=none;Username=none;Password=none;Timeout=1" },
            keys);
        return new Host(factory, factory.CreateClient(), key, keys, string.Empty);
    }

    private static string NewNonce() => Guid.NewGuid().ToString("N");

    private static string IdentityToken(Host host, string nonce, string? subject = null, Action<TokenTweaks>? tweak = null)
    {
        var t = new TokenTweaks();
        tweak?.Invoke(t);
        return AppleTestTokens.Mint(
            t.Key ?? host.Key, DateTimeOffset.UtcNow, nonce, subject ?? AppleTestTokens.Subject, t.Issuer, t.Audience, t.Lifetime, null, t.NonceClaim, true, t.KeyId);
    }

    private sealed class TokenTweaks
    {
        public AppleTestKey? Key { get; set; }
        public string Issuer { get; set; } = AppleIdentityOptions.Issuer;
        public string Audience { get; set; } = AppleTestTokens.ClientId;
        public TimeSpan? Lifetime { get; set; }
        public string? NonceClaim { get; set; }
        public string? KeyId { get; set; }
    }

    private static Task<HttpResponseMessage> PostAsync(HttpClient client, Uri uri, object body) => client.PostAsJsonAsync(uri, body);

    private static Task<HttpResponseMessage> SignInAsync(Host host, string identityToken, string nonce, Guid? deviceId = null) =>
        PostAsync(host.Client, AppleUri, deviceId is null
            ? new { identityToken, nonce }
            : new { identityToken, nonce, deviceId });

    private static Task<HttpResponseMessage> RefreshAsync(Host host, string refreshToken, Guid? deviceId = null) =>
        PostAsync(host.Client, RefreshUri, deviceId is null ? new { refreshToken } : new { refreshToken, deviceId });

    private static async Task<Tokens> ReadTokensAsync(HttpResponseMessage response)
    {
        response.StatusCode.ShouldBe(HttpStatusCode.OK, await response.Content.ReadAsStringAsync());
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        var root = document.RootElement;
        var user = root.GetProperty("user");
        return new Tokens(
            root.GetProperty("accessToken").GetString()!,
            root.GetProperty("refreshToken").GetString()!,
            root.GetProperty("expiresInSeconds").GetInt32(),
            user.GetProperty("id").GetGuid());
    }

    private sealed record Tokens(string AccessToken, string RefreshToken, int ExpiresInSeconds, Guid UserId);

    private async Task<Tokens> SignInOkAsync(Host host, string? subject = null, Guid? deviceId = null)
    {
        var nonce = NewNonce();
        return await ReadTokensAsync(await SignInAsync(host, IdentityToken(host, nonce, subject), nonce, deviceId));
    }

    private static async Task<JsonElement> ReadProblemAsync(HttpResponseMessage response, HttpStatusCode status, string code)
    {
        response.StatusCode.ShouldBe(status);
        response.Content.Headers.ContentType?.MediaType.ShouldBe("application/problem+json");
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        var root = document.RootElement.Clone();
        root.GetProperty("status").GetInt32().ShouldBe((int)status);
        root.GetProperty("code").GetString().ShouldBe(code);
        root.GetProperty("traceId").GetString().ShouldNotBeNullOrWhiteSpace();
        return root;
    }

    private static async Task AssertGenericUnauthorizedAsync(HttpResponseMessage response)
    {
        var problem = await ReadProblemAsync(response, HttpStatusCode.Unauthorized, "unauthorized");
        problem.GetProperty("title").GetString().ShouldBe("Authentication failed.");
        // Why it failed is never told to the caller (ADR-071).
        problem.TryGetProperty("detail", out _).ShouldBeFalse();
        problem.TryGetProperty("errors", out _).ShouldBeFalse();
        response.Headers.CacheControl?.NoStore.ShouldBeTrue();
    }

    private async Task<T> ScalarAsync<T>(Host host, string sql)
    {
        await using var dataSource = NpgsqlDataSource.Create(host.ConnectionString);
        await using var command = dataSource.CreateCommand(sql);
        return (T)(await command.ExecuteScalarAsync())!;
    }

    private async Task ExecAsync(Host host, string sql)
    {
        await using var dataSource = NpgsqlDataSource.Create(host.ConnectionString);
        await using var command = dataSource.CreateCommand(sql);
        await command.ExecuteNonQueryAsync();
    }

    private static HttpRequestMessage Bearer(Uri uri, string token)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, uri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return request;
    }

    // ---- sign in and the session --------------------------------------------------------------------------------

    [Fact]
    public async Task Sign_in_creates_the_user_and_the_access_token_opens_the_API()
    {
        await using var host = await StartAsync("auth_signin");
        var nonce = NewNonce();

        var response = await SignInAsync(host, IdentityToken(host, nonce), nonce);

        response.Headers.CacheControl?.NoStore.ShouldBeTrue();
        var tokens = await ReadTokensAsync(response);
        tokens.ExpiresInSeconds.ShouldBe(900);
        RefreshTokenSecret.IsWellFormed(tokens.RefreshToken).ShouldBeTrue();
        (await ScalarAsync<Guid>(host, $"SELECT id FROM users WHERE apple_subject = '{AppleTestTokens.Subject}'")).ShouldBe(tokens.UserId);

        using var me = await host.Client.SendAsync(Bearer(MeUri, tokens.AccessToken));
        me.StatusCode.ShouldBe(HttpStatusCode.OK);
        using var profile = JsonDocument.Parse(await me.Content.ReadAsStringAsync());
        profile.RootElement.GetProperty("id").GetGuid().ShouldBe(tokens.UserId);
        profile.RootElement.GetProperty("displayName").ValueKind.ShouldBe(JsonValueKind.Null);
    }

    [Fact]
    public async Task The_response_has_the_AuthTokens_shape()
    {
        await using var host = await StartAsync("auth_shape");
        var nonce = NewNonce();

        var response = await SignInAsync(host, IdentityToken(host, nonce), nonce);

        response.Content.Headers.ContentType?.MediaType.ShouldBe("application/json");
        using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        body.RootElement.EnumerateObject().Select(p => p.Name).Order().ShouldBe(["accessToken", "expiresInSeconds", "refreshToken", "user"]);
        body.RootElement.GetProperty("user").EnumerateObject().Select(p => p.Name).Order().ShouldBe(["createdAt", "displayName", "id", "timezone"]);
    }

    [Fact]
    public async Task Signing_in_again_finds_the_same_user_and_starts_another_session()
    {
        await using var host = await StartAsync("auth_again");

        var first = await SignInOkAsync(host);
        var second = await SignInOkAsync(host);

        second.UserId.ShouldBe(first.UserId);
        second.RefreshToken.ShouldNotBe(first.RefreshToken);
        (await ScalarAsync<long>(host, "SELECT count(*) FROM users")).ShouldBe(1);
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_families")).ShouldBe(2);
        // The first session is untouched by the second sign-in.
        (await RefreshAsync(host, first.RefreshToken)).StatusCode.ShouldBe(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Different_apple_subjects_are_different_users()
    {
        await using var host = await StartAsync("auth_subjects");

        var a = await SignInOkAsync(host, "sub-a");
        var b = await SignInOkAsync(host, "sub-b");

        a.UserId.ShouldNotBe(b.UserId);
        (await ScalarAsync<long>(host, "SELECT count(*) FROM users")).ShouldBe(2);
    }

    [Fact]
    public async Task Concurrent_first_sign_ins_for_one_subject_end_on_one_user()
    {
        await using var host = await StartAsync("auth_race_signin");

        var results = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => SignInOkAsync(host)));

        results.Select(r => r.UserId).Distinct().Count().ShouldBe(1);
        (await ScalarAsync<long>(host, "SELECT count(*) FROM users")).ShouldBe(1);
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_families")).ShouldBe(8);
    }

    [Fact]
    public async Task A_nonce_works_once_so_a_replayed_identity_token_is_refused()
    {
        await using var host = await StartAsync("auth_replay");
        var nonce = NewNonce();
        var token = IdentityToken(host, nonce);

        (await SignInAsync(host, token, nonce)).StatusCode.ShouldBe(HttpStatusCode.OK);

        await AssertGenericUnauthorizedAsync(await SignInAsync(host, token, nonce));
        // Even a fresh token that reuses the nonce is a replay of the sign-in.
        await AssertGenericUnauthorizedAsync(await SignInAsync(host, IdentityToken(host, nonce), nonce));
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_families")).ShouldBe(1);
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_apple_nonces")).ShouldBe(1);
    }

    [Fact]
    public async Task Concurrent_replays_of_one_token_sign_in_exactly_once()
    {
        await using var host = await StartAsync("auth_race_replay");
        var nonce = NewNonce();
        var token = IdentityToken(host, nonce);

        var responses = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => SignInAsync(host, token, nonce)));

        responses.Count(r => r.StatusCode == HttpStatusCode.OK).ShouldBe(1);
        responses.Count(r => r.StatusCode == HttpStatusCode.Unauthorized).ShouldBe(7);
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_families")).ShouldBe(1);
    }

    [Fact]
    public async Task Nonces_are_remembered_only_until_their_token_has_expired()
    {
        await using var host = await StartAsync("auth_nonce_purge");
        var nonce = NewNonce();
        (await SignInAsync(host, IdentityToken(host, nonce), nonce)).StatusCode.ShouldBe(HttpStatusCode.OK);

        // Age the stored nonce past its retention: the next sign-in purges it.
        await ExecAsync(host, "UPDATE auth_apple_nonces SET expires_at = now() - interval '1 hour'");
        var other = NewNonce();
        (await SignInAsync(host, IdentityToken(host, other), other)).StatusCode.ShouldBe(HttpStatusCode.OK);

        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_apple_nonces")).ShouldBe(1);
    }

    public static TheoryData<string> BadAppleTokens() => new()
    {
        "wrong audience",
        "wrong issuer",
        "expired",
        "nonce mismatch",
        "unknown key id",
        "signed by another key",
        "garbage",
    };

    [Theory]
    [MemberData(nameof(BadAppleTokens))]
    public async Task A_bad_identity_token_is_the_same_generic_401_and_creates_nothing(string kind)
    {
        await using var host = await StartAsync("auth_bad_" + kind.Replace(' ', '_')[..Math.Min(kind.Length, 12)]);
        using var other = AppleTestKey.Create("OTHER");
        var nonce = NewNonce();
        var (token, sentNonce) = kind switch
        {
            "wrong audience" => (IdentityToken(host, nonce, null, t => t.Audience = "com.someone.else"), nonce),
            "wrong issuer" => (IdentityToken(host, nonce, null, t => t.Issuer = "https://evil.example"), nonce),
            "expired" => (IdentityToken(host, nonce, null, t => t.Lifetime = TimeSpan.FromMinutes(-5)), nonce),
            "nonce mismatch" => (IdentityToken(host, nonce), NewNonce()),
            "unknown key id" => (IdentityToken(host, nonce, null, t => { t.Key = other; }), nonce),
            "signed by another key" => (IdentityToken(host, nonce, null, t => { t.Key = other; t.KeyId = host.Key.KeyId; }), nonce),
            _ => ("this-is-not-a-jwt", nonce),
        };

        var response = await SignInAsync(host, token, sentNonce);

        await AssertGenericUnauthorizedAsync(response);
        (await ScalarAsync<long>(host, "SELECT count(*) FROM users")).ShouldBe(0);
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_apple_nonces")).ShouldBe(0);
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_families")).ShouldBe(0);
    }

    [Fact]
    public async Task The_refusal_reason_is_logged_as_a_code_and_never_with_the_token()
    {
        await using var host = await StartAsync("auth_reason_log");
        var nonce = NewNonce();
        var token = IdentityToken(host, nonce, null, t => t.Audience = "com.someone.else");

        (await SignInAsync(host, token, nonce)).StatusCode.ShouldBe(HttpStatusCode.Unauthorized);

        host.Factory.Logs.Entries.ShouldContain(e => e.Contains("Apple sign-in refused") && e.Contains(nameof(AuthFailure.TokenAudience)));
        host.Factory.Logs.Entries.ShouldAllBe(e => !e.Contains(token) && !e.Contains(nonce));
    }

    [Fact]
    public async Task When_Apples_keys_cannot_be_fetched_sign_in_is_503_with_Retry_After()
    {
        await using var host = await StartAsync("auth_503");
        host.Keys.Unavailable = true;
        var nonce = NewNonce();

        var response = await SignInAsync(host, IdentityToken(host, nonce), nonce);

        response.Headers.RetryAfter.ShouldNotBeNull();
        await ReadProblemAsync(response, HttpStatusCode.ServiceUnavailable, "service_unavailable");
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_apple_nonces")).ShouldBe(0);
    }

    [Fact]
    public async Task A_key_rotated_at_Apple_is_picked_up_without_a_restart()
    {
        await using var host = await StartAsync("auth_rotation");
        using var next = AppleTestKey.Create("ROTATED");
        host.Keys.RotateOnRefresh(host.Key, next);

        var nonce = NewNonce();
        var tokens = await ReadTokensAsync(await SignInAsync(host, IdentityToken(host, nonce, null, t => t.Key = next), nonce));

        tokens.UserId.ShouldNotBe(Guid.Empty);
        host.Keys.ForcedRefreshes.ShouldBe(1);
    }

    [Fact]
    public async Task Sign_in_is_disabled_in_Development_without_a_client_id()
    {
        await using var host = await StartAsync("auth_noclient", "Development", (AuthTestConfig.ClientIdSetting, ""));
        var nonce = NewNonce();

        var response = await SignInAsync(host, IdentityToken(host, nonce), nonce);

        await ReadProblemAsync(response, HttpStatusCode.ServiceUnavailable, "service_unavailable");
    }

    // ---- refresh ------------------------------------------------------------------------------------------------

    [Fact]
    public async Task Refresh_rotates_the_token_and_a_spent_token_revokes_the_whole_session()
    {
        await using var host = await StartAsync("auth_rotate");
        var signedIn = await SignInOkAsync(host);

        var rotated = await ReadTokensAsync(await RefreshAsync(host, signedIn.RefreshToken));

        rotated.UserId.ShouldBe(signedIn.UserId);
        rotated.RefreshToken.ShouldNotBe(signedIn.RefreshToken);
        rotated.ExpiresInSeconds.ShouldBe(900);
        using (var me = await host.Client.SendAsync(Bearer(MeUri, rotated.AccessToken)))
        {
            me.StatusCode.ShouldBe(HttpStatusCode.OK);
        }

        // Replaying the spent token: refused, and it takes the new token down with it.
        await AssertGenericUnauthorizedAsync(await RefreshAsync(host, signedIn.RefreshToken));
        await AssertGenericUnauthorizedAsync(await RefreshAsync(host, rotated.RefreshToken));
        (await ScalarAsync<string>(host, "SELECT revoked_reason FROM auth_refresh_families")).ShouldBe("reuse");
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_tokens")).ShouldBe(2);
    }

    [Fact]
    public async Task A_revoked_session_keeps_its_access_token_until_that_expires()
    {
        await using var host = await StartAsync("auth_access_after_revoke");
        var signedIn = await SignInOkAsync(host);
        (await RefreshAsync(host, signedIn.RefreshToken)).StatusCode.ShouldBe(HttpStatusCode.OK);
        (await RefreshAsync(host, signedIn.RefreshToken)).StatusCode.ShouldBe(HttpStatusCode.Unauthorized);

        // ADR-071: access tokens are not checked against the database, which is why they are short lived.
        using var me = await host.Client.SendAsync(Bearer(MeUri, signedIn.AccessToken));
        me.StatusCode.ShouldBe(HttpStatusCode.OK);
    }

    [Fact]
    public async Task A_chain_of_refreshes_each_with_the_newest_token_keeps_working()
    {
        await using var host = await StartAsync("auth_chain");
        var current = await SignInOkAsync(host);

        for (var i = 0; i < 5; i++)
        {
            var next = await ReadTokensAsync(await RefreshAsync(host, current.RefreshToken));
            next.RefreshToken.ShouldNotBe(current.RefreshToken);
            current = next;
        }

        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_tokens")).ShouldBe(6);
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_tokens WHERE used_at IS NULL")).ShouldBe(1);
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_families WHERE revoked_at IS NOT NULL")).ShouldBe(0);
    }

    [Fact]
    public async Task Concurrent_refreshes_of_one_token_let_exactly_one_win_and_then_end_the_session()
    {
        await using var host = await StartAsync("auth_race_refresh");

        // Repeated, because the interleaving differs from run to run; the outcome must not.
        for (var round = 0; round < 3; round++)
        {
            var signedIn = await SignInOkAsync(host, $"sub-{round}");

            var responses = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => RefreshAsync(host, signedIn.RefreshToken)));

            var winners = responses.Where(r => r.StatusCode == HttpStatusCode.OK).ToList();
            winners.Count.ShouldBe(1, $"round {round}");
            responses.Count(r => r.StatusCode == HttpStatusCode.Unauthorized).ShouldBe(7, $"round {round}");

            // The losers presented a spent token, so the family is revoked and the winner's token is dead too.
            var winner = await ReadTokensAsync(winners[0]);
            await AssertGenericUnauthorizedAsync(await RefreshAsync(host, winner.RefreshToken));
        }

        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_families WHERE revoked_reason = 'reuse'")).ShouldBe(3);
        // At no point did a family hold two live tokens (the partial unique index would have refused the insert).
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_tokens WHERE used_at IS NULL")).ShouldBe(3);
    }

    [Fact]
    public async Task The_server_stores_only_the_hash_of_a_refresh_token()
    {
        await using var host = await StartAsync("auth_hash_only");
        var tokens = await SignInOkAsync(host);

        var stored = await ScalarAsync<byte[]>(host, "SELECT token_sha256 FROM auth_refresh_tokens");

        stored.ShouldBe(SHA256.HashData(Encoding.UTF8.GetBytes(tokens.RefreshToken)));
        var nonceStored = await ScalarAsync<byte[]>(host, "SELECT nonce_sha256 FROM auth_apple_nonces");
        nonceStored.Length.ShouldBe(32);
    }

    [Fact]
    public async Task Unknown_malformed_and_foreign_refresh_tokens_are_the_same_generic_401()
    {
        await using var host = await StartAsync("auth_unknown_refresh");
        await SignInOkAsync(host);

        foreach (var token in new[] { RefreshTokenSecret.Create(), "x1234567890", new string('A', 43), "not a token at all" })
        {
            await AssertGenericUnauthorizedAsync(await RefreshAsync(host, token));
        }

        // Nothing was revoked by guesses.
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_families WHERE revoked_at IS NOT NULL")).ShouldBe(0);
    }

    [Fact]
    public async Task An_expired_refresh_token_is_refused_without_revoking_the_session()
    {
        await using var host = await StartAsync("auth_expired_refresh");
        var tokens = await SignInOkAsync(host);
        await ExecAsync(host, "UPDATE auth_refresh_tokens SET created_at = now() - interval '2 days', expires_at = now() - interval '1 day'");

        await AssertGenericUnauthorizedAsync(await RefreshAsync(host, tokens.RefreshToken));

        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_families WHERE revoked_at IS NOT NULL")).ShouldBe(0);
    }

    [Fact]
    public async Task A_session_past_its_absolute_cap_cannot_refresh_and_a_late_rotation_never_outlives_it()
    {
        await using var host = await StartAsync("auth_family_cap");
        var tokens = await SignInOkAsync(host);

        // One hour left on the session: the next token is clamped to it instead of getting 60 days.
        await ExecAsync(host, "UPDATE auth_refresh_families SET created_at = now() - interval '179 days', expires_at = now() + interval '1 hour'");
        (await RefreshAsync(host, tokens.RefreshToken)).StatusCode.ShouldBe(HttpStatusCode.OK);
        (await ScalarAsync<bool>(host, """
            SELECT t.expires_at = f.expires_at
            FROM auth_refresh_tokens t JOIN auth_refresh_families f ON f.id = t.family_id
            WHERE t.used_at IS NULL
            """)).ShouldBeTrue();

    }

    [Fact]
    public async Task The_session_cap_refuses_a_refresh_once_it_has_passed()
    {
        await using var host = await StartAsync("auth_family_over");
        var tokens = await SignInOkAsync(host);
        await ExecAsync(host, "UPDATE auth_refresh_families SET created_at = now() - interval '181 days', expires_at = now() - interval '1 day'");

        await AssertGenericUnauthorizedAsync(await RefreshAsync(host, tokens.RefreshToken));
    }

    [Fact]
    public async Task A_refresh_from_another_device_is_refused_and_one_without_a_device_is_not()
    {
        await using var host = await StartAsync("auth_device");
        var device = Guid.NewGuid();
        var tokens = await SignInOkAsync(host, deviceId: device);

        await AssertGenericUnauthorizedAsync(await RefreshAsync(host, tokens.RefreshToken, Guid.NewGuid()));
        // A mismatch is a client mistake, not proof of theft: the session stays usable.
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_families WHERE revoked_at IS NOT NULL")).ShouldBe(0);

        var withDevice = await ReadTokensAsync(await RefreshAsync(host, tokens.RefreshToken, device));
        (await RefreshAsync(host, withDevice.RefreshToken)).StatusCode.ShouldBe(HttpStatusCode.OK);
    }

    [Fact]
    public async Task A_deleted_user_cannot_refresh_or_sign_in_and_the_session_is_revoked()
    {
        await using var host = await StartAsync("auth_deleted");
        var tokens = await SignInOkAsync(host);
        await ExecAsync(host, "UPDATE users SET deleted_at = now()");

        await AssertGenericUnauthorizedAsync(await RefreshAsync(host, tokens.RefreshToken));
        (await ScalarAsync<string>(host, "SELECT revoked_reason FROM auth_refresh_families")).ShouldBe("user_unavailable");

        var nonce = NewNonce();
        var token = IdentityToken(host, nonce);
        await AssertGenericUnauthorizedAsync(await SignInAsync(host, token, nonce));
        (await ScalarAsync<long>(host, "SELECT count(*) FROM auth_refresh_families")).ShouldBe(1);

        // The refused sign-in did not use up the nonce: once the account is back, the same token works.
        await ExecAsync(host, "UPDATE users SET deleted_at = NULL");
        (await SignInAsync(host, token, nonce)).StatusCode.ShouldBe(HttpStatusCode.OK);
    }

    // ---- request validation -------------------------------------------------------------------------------------

    public static TheoryData<string, string> BadBodies() => new()
    {
        { "apple", "{}" },
        { "apple", """{"identityToken":"aaaaaaaaaaaa"}""" },
        { "apple", """{"nonce":"nnnnnnnnnn"}""" },
        { "apple", """{"identityToken":"short","nonce":"nnnnnnnnnn"}""" },
        { "apple", """{"identityToken":"aaaaaaaaaaaa","nonce":"short"}""" },
        { "apple", """{"identityToken":123,"nonce":"nnnnnnnnnn"}""" },
        { "apple", """{"identityToken":"aaaaaaaaaaaa","nonce":"nnnnnnnnnn","deviceId":"not-a-uuid"}""" },
        { "apple", """{"identityToken":"aaaaaaaaaaaa","nonce":"nnnnnnnnnn","deviceId":"00000000-0000-0000-0000-000000000000"}""" },
        { "apple", """{"identityToken":"aaaaaaaaaaaa","nonce":"nnnnnnnnnn","deviceId":5}""" },
        { "apple", "[]" },
        { "apple", "\"text\"" },
        { "refresh", "{}" },
        { "refresh", """{"refreshToken":"short"}""" },
        { "refresh", """{"refreshToken":42}""" },
        { "refresh", """{"deviceId":"7ac1b1c2-7a67-4c0d-8c0b-3e4d3d6c9a11"}""" },
        { "refresh", """{"refreshToken":"aaaaaaaaaaaa","deviceId":"nope"}""" },
        { "refresh", "[1]" },
    };

    [Theory]
    [MemberData(nameof(BadBodies))]
    public async Task A_body_that_breaks_the_schema_is_400_validation_failed(string endpoint, string body)
    {
        await using var host = StartWithoutDatabase();
        using var content = new StringContent(body, Encoding.UTF8, "application/json");

        var response = await host.Client.PostAsync(endpoint == "apple" ? AppleUri : RefreshUri, content);

        await ReadProblemAsync(response, HttpStatusCode.BadRequest, "validation_failed");
        response.Headers.CacheControl?.NoStore.ShouldBeTrue();
    }

    [Fact]
    public async Task The_length_limits_match_the_contract()
    {
        await using var host = StartWithoutDatabase();

        (await PostAsync(host.Client, AppleUri, new { identityToken = new string('a', 8193), nonce = "nnnnnnnnnn" })).StatusCode.ShouldBe(HttpStatusCode.BadRequest);
        (await PostAsync(host.Client, AppleUri, new { identityToken = new string('a', 8192), nonce = new string('n', 257) })).StatusCode.ShouldBe(HttpStatusCode.BadRequest);
        (await PostAsync(host.Client, RefreshUri, new { refreshToken = new string('a', 129) })).StatusCode.ShouldBe(HttpStatusCode.BadRequest);
        // At the limit the request is valid and then refused as a credential, not as a bad body.
        await AssertGenericUnauthorizedAsync(await PostAsync(host.Client, AppleUri, new { identityToken = new string('a', 8192), nonce = new string('n', 256) }));
        await AssertGenericUnauthorizedAsync(await PostAsync(host.Client, RefreshUri, new { refreshToken = new string('a', 128) }));
    }

    [Theory]
    [InlineData("apple")]
    [InlineData("refresh")]
    public async Task Invalid_json_is_400_a_wrong_content_type_is_415_and_a_big_body_is_413(string endpoint)
    {
        await using var host = StartWithoutDatabase();
        var uri = endpoint == "apple" ? AppleUri : RefreshUri;

        using (var broken = new StringContent("{ not json", Encoding.UTF8, "application/json"))
        {
            await ReadProblemAsync(await host.Client.PostAsync(uri, broken), HttpStatusCode.BadRequest, "bad_request");
        }

        using (var text = new StringContent("{}", Encoding.UTF8, "text/plain"))
        {
            await ReadProblemAsync(await host.Client.PostAsync(uri, text), HttpStatusCode.UnsupportedMediaType, "unsupported_media_type");
        }

        using (var big = new StringContent($$"""{"identityToken":"{{new string('a', 20 * 1024)}}","nonce":"nnnnnnnnnn"}""", Encoding.UTF8, "application/json"))
        {
            await ReadProblemAsync(await host.Client.PostAsync(uri, big), HttpStatusCode.RequestEntityTooLarge, "payload_too_large");
        }
    }

    [Fact]
    public async Task Both_endpoints_are_anonymous_and_a_bearer_token_is_ignored()
    {
        await using var host = await StartAsync("auth_anon");
        var signedIn = await SignInOkAsync(host);

        using var request = new HttpRequestMessage(HttpMethod.Post, RefreshUri)
        {
            Content = JsonContent.Create(new { refreshToken = signedIn.RefreshToken }),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "garbage-not-a-jwt");

        (await host.Client.SendAsync(request)).StatusCode.ShouldBe(HttpStatusCode.OK);
    }

    // ---- rate limiting and logs ---------------------------------------------------------------------------------

    [Fact]
    public async Task Both_endpoints_share_a_per_IP_budget_and_answer_429_with_Retry_After()
    {
        await using var host = await StartAsync("auth_ratelimit", "Development", ("RateLimiting:Auth:PermitLimit", "3"), ("RateLimiting:Auth:WindowSeconds", "60"));

        for (var i = 0; i < 3; i++)
        {
            (await RefreshAsync(host, RefreshTokenSecret.Create())).StatusCode.ShouldBe(HttpStatusCode.Unauthorized);
        }

        var limited = await SignInAsync(host, "identity-token-0001", "nonce-0001-xx");

        limited.Headers.RetryAfter.ShouldNotBeNull();
        await ReadProblemAsync(limited, HttpStatusCode.TooManyRequests, "rate_limited");
        (await RefreshAsync(host, RefreshTokenSecret.Create())).StatusCode.ShouldBe(HttpStatusCode.TooManyRequests);
    }

    [Fact]
    public async Task Tokens_nonces_and_the_apple_subject_never_reach_the_logs()
    {
        await using var host = await StartAsync("auth_logs");
        var nonce = NewNonce();
        var identityToken = IdentityToken(host, nonce);
        var signedIn = await ReadTokensAsync(await SignInAsync(host, identityToken, nonce));
        var rotated = await ReadTokensAsync(await RefreshAsync(host, signedIn.RefreshToken));
        (await RefreshAsync(host, signedIn.RefreshToken)).StatusCode.ShouldBe(HttpStatusCode.Unauthorized); // reuse: logged as a warning
        (await SignInAsync(host, identityToken, nonce)).StatusCode.ShouldBe(HttpStatusCode.Unauthorized); // replay

        var logs = host.Factory.Logs.Entries;
        logs.ShouldNotBeEmpty();
        logs.ShouldContain(e => e.Contains(nameof(AuthFailure.RefreshReused)));
        logs.ShouldContain(e => e.Contains(nameof(AuthFailure.NonceReused)));
        string[] secrets =
        [
            identityToken, identityToken[(identityToken.LastIndexOf('.') + 1)..], nonce, AppleNonce.ExpectedClaim(nonce),
            signedIn.AccessToken, signedIn.RefreshToken, rotated.AccessToken, rotated.RefreshToken,
            host.Factory.AccessKey, AppleTestTokens.Subject,
        ];
        foreach (var entry in logs)
        {
            foreach (var secret in secrets)
            {
                entry.ShouldNotContain(secret);
            }
        }
    }

    // ---- bearer validation of the CALI issuer -------------------------------------------------------------------

    [Fact]
    public async Task Outside_Development_the_access_token_from_sign_in_is_accepted_and_dev_tokens_are_not()
    {
        await using var host = await StartAsync("auth_production", "Production");
        var tokens = await SignInOkAsync(host);

        using (var ok = await host.Client.SendAsync(Bearer(MeUri, tokens.AccessToken)))
        {
            ok.StatusCode.ShouldBe(HttpStatusCode.OK);
        }

        var devKey = DevSigningKey.Generate();
        DevSigningKey.TryParse(devKey, out var parsed, out _).ShouldBeTrue();
        using var dev = await host.Client.SendAsync(Bearer(MeUri, DevTokenFactory.Create(tokens.UserId, TimeSpan.FromHours(1), DateTimeOffset.UtcNow, parsed)));
        dev.StatusCode.ShouldBe(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task Access_tokens_that_are_tampered_foreign_expired_or_for_another_audience_are_rejected()
    {
        await using var host = await StartAsync("auth_bad_access");
        var signedIn = await SignInOkAsync(host);
        var key = Convert.FromBase64String(host.Factory.AccessKey);
        var userId = signedIn.UserId;
        var tokens = new Dictionary<string, string>
        {
            ["tampered"] = signedIn.AccessToken[..^3] + (signedIn.AccessToken.EndsWith("AAA", StringComparison.Ordinal) ? "BBB" : "AAA"),
            ["another key"] = new AccessTokenIssuer(RandomNumberGenerator.GetBytes(32), "cali-api", TimeSpan.FromMinutes(15), TimeProvider.System).Issue(userId).Token,
            ["expired"] = new AccessTokenIssuer(key, "cali-api", TimeSpan.FromMinutes(15), new FixedTimeProvider(DateTimeOffset.UtcNow.AddHours(-2))).Issue(userId).Token,
            ["another audience"] = new AccessTokenIssuer(key, "somebody-else", TimeSpan.FromMinutes(15), TimeProvider.System).Issue(userId).Token,
        };

        foreach (var (name, token) in tokens)
        {
            using var response = await host.Client.SendAsync(Bearer(MeUri, token));
            response.StatusCode.ShouldBe(HttpStatusCode.Unauthorized, name);
        }
    }

    [Fact]
    public async Task Configured_lifetimes_are_used()
    {
        await using var host = await StartAsync("auth_lifetimes", "Development", ("Auth:AccessTokenMinutes", "5"));

        (await SignInOkAsync(host)).ExpiresInSeconds.ShouldBe(300);
    }

    // ---- startup ------------------------------------------------------------------------------------------------

    [Theory]
    [InlineData("Auth:AccessTokenSigningKey", "", "Production")]
    [InlineData("Auth:AccessTokenSigningKey", "bm90LWxvbmctZW5vdWdo", "Production")]
    [InlineData("Auth:AccessTokenSigningKey", "bm90LWxvbmctZW5vdWdo", "Development")]
    [InlineData("Auth:Apple:ClientId", "", "Production")]
    [InlineData("Auth:RefreshTokenDays", "0", "Production")]
    public void The_host_refuses_to_start_with_a_bad_auth_configuration(string key, string value, string environment)
    {
        using var keyPair = AppleTestKey.Create();
        using var factory = new AuthApiFactory(
            environment,
            new Dictionary<string, string?> { ["ConnectionStrings:Cali"] = "Host=127.0.0.1;Port=1;Database=none;Username=none;Password=none", [key] = value },
            new FakeAppleKeySetProvider(keyPair));

        var error = Should.Throw<Exception>(() => factory.CreateClient());

        error.ToString().ShouldContain(key);
        error.ToString().ShouldNotContain(value is { Length: > 8 } ? value : "\u0000never");
    }
}
