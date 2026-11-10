namespace Cali.Application.Sync;

/// <summary>One <c>sync_change_log</c> row.</summary>
public sealed record SyncChangeRecord(long Seq, string EntityType, Guid EntityId, string Operation, long ServerVersion, string PayloadJson);

/// <summary>
/// What the feed knows about a cursor position: the user's highest allocated <c>seq</c> (0 when the user has
/// never written) and when the change at that position was logged (null when that row does not exist).
/// </summary>
public sealed record SyncCursorState(long LastSeq, DateTime? ChangedAtUtc);

public interface ISyncReader
{
    Task<SyncCursorState> GetCursorStateAsync(Guid userId, long seq, CancellationToken cancellationToken);

    /// <summary>The user's changes with <c>seq</c> strictly greater than <paramref name="afterSeq"/>, ascending. Always scoped to <paramref name="userId"/>.</summary>
    Task<IReadOnlyList<SyncChangeRecord>> ReadChangesAsync(Guid userId, long afterSeq, int take, CancellationToken cancellationToken);
}

/// <summary>How long a cursor stays usable (docs/08 §7, ADR-070).</summary>
public sealed record SyncPullSettings(TimeSpan Retention)
{
    public const int DefaultRetentionDays = 180;
}

public enum SyncPullStatus
{
    Page,

    /// <summary>The cursor is malformed, was not signed by this server or belongs to another user.</summary>
    InvalidCursor,

    /// <summary>The cursor is older than the retention window or ahead of the feed: the device must resync from scratch.</summary>
    CursorExpired,
}

public sealed record SyncPullChange(string ChangeId, SyncChangeRecord Record);

public sealed record SyncPullPage(IReadOnlyList<SyncPullChange> Changes, string NextCursor, bool HasMore);

public sealed record SyncPullResult(SyncPullStatus Status, SyncPullPage? Page = null);

/// <summary>Use case behind <c>GET /v1/sync/pull</c> (BE-004).</summary>
public sealed class PullChanges(ISyncReader reader, SyncCursorCodec codec, SyncPullSettings settings, TimeProvider time)
{
    public const int DefaultLimit = 100;
    public const int MaxLimit = 100;

    /// <param name="cursor">Null for the initial sync (the whole feed from the start).</param>
    public async Task<SyncPullResult> ExecuteAsync(Guid userId, string? cursor, int limit, CancellationToken cancellationToken)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 1);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(limit, MaxLimit);

        long after = 0;
        if (cursor is not null && !codec.TryDecode(cursor, userId, out after))
        {
            return new SyncPullResult(SyncPullStatus.InvalidCursor);
        }

        if (after > 0 && await IsExpiredAsync(userId, after, cancellationToken).ConfigureAwait(false))
        {
            return new SyncPullResult(SyncPullStatus.CursorExpired);
        }

        // One extra row tells whether another page exists without a COUNT query.
        var rows = await reader.ReadChangesAsync(userId, after, limit + 1, cancellationToken).ConfigureAwait(false);
        var hasMore = rows.Count > limit;
        var records = hasMore ? rows.Take(limit).ToArray() : rows;
        var next = records.Count > 0 ? records[^1].Seq : after;
        var changes = records.Select(r => new SyncPullChange(codec.Encode(userId, r.Seq), r)).ToArray();
        return new SyncPullResult(SyncPullStatus.Page, new SyncPullPage(changes, codec.Encode(userId, next), hasMore));
    }

    // A cursor is only trusted while the change it points at is still in the log and younger than the
    // retention window. A cursor ahead of the feed (after a restore, say) would otherwise skip the changes
    // that later reuse those sequence numbers.
    private async Task<bool> IsExpiredAsync(Guid userId, long after, CancellationToken cancellationToken)
    {
        var state = await reader.GetCursorStateAsync(userId, after, cancellationToken).ConfigureAwait(false);
        if (after > state.LastSeq || state.ChangedAtUtc is not { } changedAt)
        {
            return true;
        }

        var cutoff = time.GetUtcNow() - settings.Retention;
        return new DateTimeOffset(DateTime.SpecifyKind(changedAt, DateTimeKind.Utc)) < cutoff;
    }
}
