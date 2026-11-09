using System.Text.Json;
using Cali.Domain.Plans;

namespace Cali.Application.Plans;

/// <summary>Stored successful result of an idempotent request (table <c>http_idempotency_keys</c>).</summary>
public sealed record StoredIdempotentResponse(string Operation, string RequestSha256, int StatusCode, string ResponseBody);

/// <summary>What the client sent with an idempotent request: its key and the request fingerprint.</summary>
public sealed record IdempotencyRequest(Guid Key, string Operation, string RequestSha256);

public enum PlanWriteStatus
{
    Created,
    UserNotFound,
    PlanCountLimit,
    /// <summary>A unique key already exists: a plan/workout/exercise id or the idempotency key.</summary>
    UniqueViolation,
    /// <summary>A referenced row disappeared during the transaction (for example a catalog exercise).</summary>
    ForeignKeyViolation,
}

public interface IPlanWriter
{
    Task<StoredIdempotentResponse?> FindIdempotentResponseAsync(Guid userId, Guid key, CancellationToken cancellationToken);

    /// <summary>
    /// One transaction: lock the user row, insert the plan revision, workouts and exercises, append one
    /// change-log upsert per row (advancing <c>user_sync_state.last_seq</c>) and store the idempotent
    /// response. Nothing is written unless the result is <see cref="PlanWriteStatus.Created"/>.
    /// </summary>
    Task<PlanWriteStatus> CreateAsync(Guid userId, TrainingPlan plan, IdempotencyRequest idempotency, string responseBody, CancellationToken cancellationToken);
}

public enum CreatePlanStatus
{
    Created,
    Replayed,
    ValidationFailed,
    IdempotencyKeyReused,
    UserNotFound,
    PlanCountLimit,
    Conflict,
}

/// <summary>
/// <see cref="ResponseBody"/> is the serialized <c>TrainingPlan</c> (201) for Created and Replayed;
/// <see cref="Errors"/> is set for ValidationFailed.
/// </summary>
public sealed record CreatePlanResult(CreatePlanStatus Status, string? ResponseBody = null, ValidationErrors? Errors = null);

/// <summary>
/// Use case behind <c>POST /v1/plans</c> (BE-002): creates a root plan (revision 1, status current,
/// lineage = own id). Repeat calls with the same <c>Idempotency-Key</c> and request return the stored
/// 201 body; the same key with a different request is rejected (ADR-068).
/// </summary>
public sealed class CreatePlan(IPlanReader reader, IPlanWriter writer)
{
    public const string Operation = "createPlan";

    private static readonly JsonSerializerOptions ResponseJson = new(JsonSerializerDefaults.Web);

    public async Task<CreatePlanResult> ExecuteAsync(
        Guid userId, Guid idempotencyKey, string requestSha256, CreatePlanInput input, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(input);
        var idempotency = new IdempotencyRequest(idempotencyKey, Operation, requestSha256);

        if (await ReplayAsync(userId, idempotency, cancellationToken).ConfigureAwait(false) is { } earlier)
        {
            return earlier;
        }

        var exerciseTypes = await reader
            .GetPublishedExerciseTypesAsync(PlanValidator.ReferencedExerciseIds(input), cancellationToken)
            .ConfigureAwait(false);
        var errors = new ValidationErrors();
        if (PlanValidator.ValidateCreate(input, exerciseTypes, errors) is not { } valid)
        {
            return new CreatePlanResult(CreatePlanStatus.ValidationFailed, Errors: errors);
        }

        var plan = new TrainingPlan(
            valid.Id, valid.Title, valid.Kind, valid.EventDate, valid.EventName, valid.PrimaryDiscipline, valid.Workouts,
            Revision: 1, Version: 1, Status: PlanRevisionStatus.Current, ParentPlanId: null, LineageId: valid.Id,
            EndedAt: null, EndReason: null, EndNote: null, ArchivedAt: null);
        var body = JsonSerializer.Serialize(plan, ResponseJson);

        var status = await writer.CreateAsync(userId, plan, idempotency, body, cancellationToken).ConfigureAwait(false);
        switch (status)
        {
            case PlanWriteStatus.Created:
                return new CreatePlanResult(CreatePlanStatus.Created, body);
            case PlanWriteStatus.UserNotFound:
                return new CreatePlanResult(CreatePlanStatus.UserNotFound);
            case PlanWriteStatus.PlanCountLimit:
                return new CreatePlanResult(CreatePlanStatus.PlanCountLimit);
            case PlanWriteStatus.UniqueViolation:
                // A concurrent request with the same key may have committed first: replay it.
                // Otherwise an id is taken (possibly by another user; the response does not say which).
                return await ReplayAsync(userId, idempotency, cancellationToken).ConfigureAwait(false)
                    ?? new CreatePlanResult(CreatePlanStatus.Conflict);
            default:
                return new CreatePlanResult(CreatePlanStatus.Conflict);
        }
    }

    private async Task<CreatePlanResult?> ReplayAsync(Guid userId, IdempotencyRequest request, CancellationToken cancellationToken)
    {
        var stored = await writer.FindIdempotentResponseAsync(userId, request.Key, cancellationToken).ConfigureAwait(false);
        if (stored is null)
        {
            return null;
        }

        return stored.Operation == request.Operation && stored.RequestSha256 == request.RequestSha256
            ? new CreatePlanResult(CreatePlanStatus.Replayed, stored.ResponseBody)
            : new CreatePlanResult(CreatePlanStatus.IdempotencyKeyReused);
    }
}
