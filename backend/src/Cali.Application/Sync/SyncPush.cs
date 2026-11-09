using Cali.Application.Catalog;
using Cali.Application.Plans;

namespace Cali.Application.Sync;

public enum SyncPushStatus
{
    Pushed,
    ValidationFailed,
    UserNotFound,
    /// <summary>The device id is registered to another user (ADR-033).</summary>
    DeviceOwnerMismatch,
}

/// <summary><see cref="Receipts"/> is set for Pushed (one per mutation, in request order); <see cref="Errors"/> for ValidationFailed.</summary>
public sealed record SyncPushResult(SyncPushStatus Status, IReadOnlyList<SyncReceipt>? Receipts = null, ValidationErrors? Errors = null);

public enum SyncWriteStatus
{
    Written,
    UserNotFound,
    DeviceOwnerMismatch,
}

public sealed record SyncWriteResult(SyncWriteStatus Status, IReadOnlyList<SyncReceipt> Receipts);

public interface ISyncWriter
{
    /// <summary>
    /// One transaction for the whole batch (ADR-069): lock the user, register the device, lock
    /// <c>user_sync_state</c>, then apply each mutation inside its own savepoint in request order.
    /// Every mutation gets exactly one receipt; a stored receipt replays as <c>duplicate</c>.
    /// </summary>
    Task<SyncWriteResult> PushAsync(Guid userId, Guid deviceId, IReadOnlyList<PreparedMutation> mutations, CancellationToken cancellationToken);
}

/// <summary>
/// Use case behind <c>POST /v1/sync/push</c> (BE-003): validates the batch, loads the server-owned
/// lookups once, prepares every mutation without touching user data and hands the batch to the writer.
/// </summary>
public sealed class SyncPush(IPlanReader planReader, ICriteriaConfigReader criteriaReader, ISyncWriter writer)
{
    public async Task<SyncPushResult> ExecuteAsync(Guid userId, System.Text.Json.JsonElement body, CancellationToken cancellationToken)
    {
        var errors = new ValidationErrors();
        if (SyncPushRequestParser.Parse(body, errors) is not { } batch)
        {
            return new SyncPushResult(SyncPushStatus.ValidationFailed, Errors: errors);
        }

        var lookups = await LoadLookupsAsync(batch.Mutations, cancellationToken).ConfigureAwait(false);
        var prepared = batch.Mutations.Select(m => SyncEntitySpecs.Prepare(m, lookups)).ToArray();
        var result = await writer.PushAsync(userId, batch.DeviceId, prepared, cancellationToken).ConfigureAwait(false);
        return result.Status switch
        {
            SyncWriteStatus.UserNotFound => new SyncPushResult(SyncPushStatus.UserNotFound),
            SyncWriteStatus.DeviceOwnerMismatch => new SyncPushResult(SyncPushStatus.DeviceOwnerMismatch),
            _ => new SyncPushResult(SyncPushStatus.Pushed, result.Receipts),
        };
    }

    private async Task<SyncLookups> LoadLookupsAsync(IReadOnlyList<SyncMutation> mutations, CancellationToken cancellationToken)
    {
        var (exerciseIds, versions, needsIndicators) = SyncEntitySpecs.LookupKeys(mutations);
        IReadOnlyDictionary<Guid, string> exerciseTypes = exerciseIds.Count == 0
            ? new Dictionary<Guid, string>()
            : await planReader.GetPublishedExerciseTypesAsync(exerciseIds, cancellationToken).ConfigureAwait(false);

        var documents = new Dictionary<int, string>();
        foreach (var version in versions)
        {
            if (await criteriaReader.FindAsync(version, cancellationToken).ConfigureAwait(false) is { } config)
            {
                documents[config.Version] = config.DocumentJson;
            }
        }

        var indicators = new Dictionary<string, Domain.Catalog.IndicatorDefinition>(StringComparer.Ordinal);
        if (needsIndicators)
        {
            var set = await criteriaReader.GetIndicatorSetAsync(cancellationToken).ConfigureAwait(false);
            foreach (var indicator in set.Indicators)
            {
                indicators[indicator.Id] = indicator;
            }
        }

        return new SyncLookups(exerciseTypes, documents, indicators);
    }
}
