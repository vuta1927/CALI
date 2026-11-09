namespace Cali.Application.Sync;

/// <summary>A row the mutation points at, checked inside the push transaction before the write (ADR-069).</summary>
public abstract record SyncReference(string Field);

/// <summary>
/// A user-owned row by id. Missing → <c>dependency_missing</c> (retryable); owned by another user →
/// <c>cross_user_reference</c>. A tombstoned parent is accepted: history keeps pointing at it.
/// </summary>
public sealed record ParentReference(string Field, string Table, Guid Id) : SyncReference(Field);

/// <summary>A plan lineage: at least one <c>training_plans</c> row of the user carries this <c>lineage_id</c>.</summary>
public sealed record LineageReference(string Field, Guid LineageId) : SyncReference(Field);

/// <summary>
/// One mutation after all checks that need no user data (schema, catalog, criteria, indicators and the
/// other ADR-020 business rules). <see cref="Rejection"/> is set when the mutation can never apply
/// (validation_failed or forbidden_entity); the writer still looks up the mutation id first so a replay
/// of a stored receipt wins. <see cref="ChangeJson"/> is the normalized entity payload appended to
/// <c>sync_change_log</c> (patched with the trigger-assigned lineage for training plans).
/// </summary>
public sealed record PreparedMutation(
    SyncMutation Mutation,
    string Fingerprint,
    string? Table,
    IReadOnlyList<SqlColumn> Columns,
    string ChangeJson,
    IReadOnlyList<SyncReference> References,
    SyncReceipt? Rejection,
    bool ServerCreatedAt)
{
    public bool IsDelete => Mutation.Action == SyncActions.Delete;

    public bool IsTrainingPlan => Mutation.EntityType == SyncEntityTypes.TrainingPlan;
}
