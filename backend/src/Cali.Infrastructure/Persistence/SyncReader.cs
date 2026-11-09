using Cali.Application.Sync;
using Dapper;
using Npgsql;

namespace Cali.Infrastructure.Persistence;

/// <summary>
/// Reads a user's change feed (BE-004). Writers allocate <c>seq</c> under the <c>user_sync_state</c> row lock and
/// hold it until commit, so rows become visible in <c>seq</c> order and a page never skips a change that
/// commits later (db/001 comment, ADR-069).
/// </summary>
public sealed class SyncReader(NpgsqlDataSource dataSource) : ISyncReader
{
    private const string CursorStateSql = """
        SELECT COALESCE((SELECT last_seq FROM user_sync_state WHERE user_id = @userId), 0) AS LastSeq,
               (SELECT changed_at FROM sync_change_log WHERE user_id = @userId AND seq = @seq) AS ChangedAtUtc
        """;

    private const string ChangesSql = """
        SELECT seq AS Seq, entity_type AS EntityType, entity_id AS EntityId, operation AS Operation,
               server_version AS ServerVersion, payload::text AS PayloadJson
        FROM sync_change_log
        WHERE user_id = @userId AND seq > @afterSeq
        ORDER BY seq
        LIMIT @take
        """;

    public async Task<SyncCursorState> GetCursorStateAsync(Guid userId, long seq, CancellationToken cancellationToken)
    {
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        return await connection.QuerySingleAsync<SyncCursorState>(
            new CommandDefinition(CursorStateSql, new { userId, seq }, cancellationToken: cancellationToken)).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<SyncChangeRecord>> ReadChangesAsync(Guid userId, long afterSeq, int take, CancellationToken cancellationToken)
    {
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        return (await connection.QueryAsync<SyncChangeRecord>(
            new CommandDefinition(ChangesSql, new { userId, afterSeq, take }, cancellationToken: cancellationToken)).ConfigureAwait(false)).AsList();
    }
}
