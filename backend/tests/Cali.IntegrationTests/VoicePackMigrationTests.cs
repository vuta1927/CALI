using Cali.Infrastructure.Persistence.Migrations;
using Cali.IntegrationTests.Infrastructure;
using Cali.Tests.Shared;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

namespace Cali.IntegrationTests;

/// <summary>CON-010: db/011_voice_packs.sql (ADR-077). Published packs are immutable and only grow by new versions.</summary>
[Collection(PostgresCollection.Name)]
public sealed class VoicePackMigrationTests(PostgresFixture postgres)
{
    private static readonly string Sha = new('a', 64);

    [Fact]
    public async Task Upgrade_from_010_adds_empty_voice_pack_tables()
    {
        var cs = await postgres.CreateDatabaseMigratedUpToAsync("voice_upgrade", "010_auth_sessions.sql", includeDevelopmentScripts: true);

        var result = new DatabaseMigrator(NullLogger<DatabaseMigrator>.Instance)
            .Run(cs, RepoPaths.DbDirectory, includeDevelopmentScripts: true);

        result.Successful.ShouldBeTrue(result.Error?.ToString());
        result.AppliedScripts.ShouldContain("011_voice_packs.sql");
        result.AppliedScripts.ShouldNotContain("010_auth_sessions.sql");
        // No placeholder pack is seeded: a published version needs rendered audio.
        (await ScalarAsync<long>(cs, "SELECT count(*) FROM voice_pack_versions")).ShouldBe(0);
    }

    [Fact]
    public async Task A_pack_is_published_with_its_cues_in_one_transaction()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("voice_publish");

        await PublishAsync(cs, 1, "rest.done", "hold.done");

        (await ScalarAsync<long>(cs, "SELECT count(*) FROM voice_cues WHERE locale = 'vi-VN' AND version = 1")).ShouldBe(2);
        (await ScalarAsync<int>(cs, "SELECT max(version) FROM voice_pack_versions WHERE locale = 'vi-VN'")).ShouldBe(1);
        await PublishAsync(cs, 2, "rest.done");
        (await ScalarAsync<int>(cs, "SELECT max(version) FROM voice_pack_versions WHERE locale = 'vi-VN'")).ShouldBe(2);
    }

    [Fact]
    public async Task A_published_pack_cannot_gain_change_or_lose_cues()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("voice_immutable");
        await PublishAsync(cs, 1, "rest.done");

        foreach (var sql in new[]
        {
            CueInsert(1, "hold.done"),
            "UPDATE voice_cues SET text = 'Khác.' WHERE cue_key = 'rest.done'",
            "DELETE FROM voice_cues",
            "UPDATE voice_pack_versions SET voice = 'other'",
            "DELETE FROM voice_pack_versions",
        })
        {
            var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs, sql));
            error.SqlState.ShouldBe(PostgresErrorCodes.RestrictViolation, sql);
            error.ConstraintName.ShouldBe("ck_voice_pack_immutable", sql);
        }
    }

    [Theory]
    [InlineData("cue_key", "'Rest'", "ck_voice_cues_key")]
    [InlineData("text", "''", "ck_voice_cues_text")]
    [InlineData("sha256", "'ABC'", "ck_voice_cues_sha256")]
    [InlineData("format", "'mp3'", "ck_voice_cues_format")]
    [InlineData("duration_ms", "30001", "ck_voice_cues_duration")]
    [InlineData("byte_size", "0", "ck_voice_cues_byte_size")]
    public async Task Constraints_reject_invalid_cues(string column, string value, string constraint)
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("voice_check");

        var error = await Should.ThrowAsync<PostgresException>(() => InTransactionAsync(cs,
            VersionInsert(1), CueInsert(1, "rest.done", column, value)));

        error.SqlState.ShouldBe(PostgresErrorCodes.CheckViolation);
        error.ConstraintName.ShouldBe(constraint);
    }

    [Fact]
    public async Task Locale_must_be_a_language_region_tag()
    {
        var cs = await postgres.CreateMigratedDatabaseAsync("voice_locale");

        var error = await Should.ThrowAsync<PostgresException>(() => ExecAsync(cs,
            "INSERT INTO voice_pack_versions (locale, version, published_at, voice) VALUES ('vi', 1, now(), 'v')"));

        error.ConstraintName.ShouldBe("ck_voice_pack_versions_locale");
    }

    private static Task PublishAsync(string cs, int version, params string[] keys) =>
        InTransactionAsync(cs, [VersionInsert(version), .. keys.Select(k => CueInsert(version, k))]);

    private static string VersionInsert(int version) =>
        $"INSERT INTO voice_pack_versions (locale, version, published_at, voice) VALUES ('vi-VN', {version}, now(), 'test voice')";

    private static string CueInsert(int version, string key, string? column = null, string? value = null)
    {
        var values = new Dictionary<string, string>
        {
            ["locale"] = "'vi-VN'",
            ["version"] = version.ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["cue_key"] = $"'{key}'",
            ["text"] = "'Hết giờ nghỉ.'",
            ["storage_key"] = $"'voice/vi-VN/v{version}/{key}.caf'",
            ["format"] = "'caf_ima4'",
            ["sha256"] = $"'{Sha}'",
            ["byte_size"] = "12000",
            ["duration_ms"] = "1800",
        };
        if (column is not null)
        {
            values[column] = value!;
        }

        return $"INSERT INTO voice_cues ({string.Join(", ", values.Keys)}) VALUES ({string.Join(", ", values.Values)})";
    }

    private static async Task InTransactionAsync(string cs, params string[] statements)
    {
        await using var connection = new NpgsqlConnection(cs);
        await connection.OpenAsync();
        await using var transaction = await connection.BeginTransactionAsync();
        foreach (var sql in statements)
        {
            await using var command = new NpgsqlCommand(sql, connection, transaction);
            await command.ExecuteNonQueryAsync();
        }

        await transaction.CommitAsync();
    }

    private static async Task<T> ScalarAsync<T>(string cs, string sql)
    {
        await using var connection = new NpgsqlConnection(cs);
        await connection.OpenAsync();
        await using var command = new NpgsqlCommand(sql, connection);
        return (T)(await command.ExecuteScalarAsync())!;
    }

    private static async Task ExecAsync(string cs, string sql)
    {
        await using var connection = new NpgsqlConnection(cs);
        await connection.OpenAsync();
        await using var command = new NpgsqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync();
    }
}
