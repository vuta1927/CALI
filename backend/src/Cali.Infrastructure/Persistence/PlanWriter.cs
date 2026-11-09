using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Cali.Application.Plans;
using Cali.Domain.Plans;
using Dapper;
using Npgsql;

namespace Cali.Infrastructure.Persistence;

/// <summary>
/// Creates plan revisions in one transaction together with their sync change-log entries (docs/06:
/// direct writes and sync push produce the same change log) and the idempotent response (ADR-068).
/// </summary>
public sealed class PlanWriter(NpgsqlDataSource dataSource) : IPlanWriter
{
    private const string PlanCountLimitSqlState = "CA002";

    private const string FindIdempotentSql = """
        SELECT operation AS Operation, request_sha256 AS RequestSha256, status_code AS StatusCode,
               response_body::text AS ResponseBody
        FROM http_idempotency_keys
        WHERE user_id = @userId AND idempotency_key = @key
        """;

    // FOR SHARE keeps the user from being deleted until commit; a deleted user cannot write.
    private const string LockUserSql = "SELECT 1 FROM users WHERE id = @userId AND deleted_at IS NULL FOR SHARE";

    // The row lock taken by the UPDATE serializes this user's writers, so seq values are gap-free
    // and commit in order (docs/06 cursor pull).
    private const string EnsureSyncStateSql = "INSERT INTO user_sync_state (user_id) VALUES (@userId) ON CONFLICT (user_id) DO NOTHING";

    private const string AdvanceSeqSql = "UPDATE user_sync_state SET last_seq = last_seq + @count WHERE user_id = @userId RETURNING last_seq";

    // created_at = clock_timestamp() AFTER the user_sync_state lock (not now() = transaction start):
    // this user's writers are serialized, so a plan committed later always sorts later and keyset
    // pages read by GET /v1/plans never miss a row that commits after they were read.
    private const string InsertPlanSql = """
        INSERT INTO training_plans (id, user_id, title, revision, parent_plan_id, status, version, lineage_id,
                                    kind, event_date, event_name, primary_discipline, created_at, updated_at)
        VALUES (@id, @userId, @title, @revision, @parentPlanId, @status, @version, @lineageId,
                @kind, CAST(@eventDate AS date), @eventName, @primaryDiscipline, clock_timestamp(), clock_timestamp())
        """;

    private const string InsertWorkoutsSql = """
        INSERT INTO planned_workouts (id, user_id, plan_id, weekday, title, order_index)
        SELECT w.id, @userId, @planId, w.weekday, w.title, w.order_index
        FROM unnest(@ids, @weekdays, @titles, @orderIndexes) AS w(id, weekday, title, order_index)
        """;

    private const string InsertExercisesSql = """
        INSERT INTO planned_exercises (id, user_id, planned_workout_id, exercise_id, order_index, set_count, target, rest_seconds)
        SELECT e.id, @userId, e.workout_id, e.exercise_id, e.order_index, e.set_count, CAST(e.target AS jsonb), e.rest_seconds
        FROM unnest(@ids, @workoutIds, @exerciseIds, @orderIndexes, @setCounts, @targets, @restSeconds)
             AS e(id, workout_id, exercise_id, order_index, set_count, target, rest_seconds)
        """;

    private const string InsertChangesSql = """
        INSERT INTO sync_change_log (user_id, seq, entity_type, entity_id, operation, server_version, payload)
        SELECT @userId, c.seq, c.entity_type, c.entity_id, 'upsert', c.server_version, CAST(c.payload AS jsonb)
        FROM unnest(@seqs, @entityTypes, @entityIds, @serverVersions, @payloads)
             AS c(seq, entity_type, entity_id, server_version, payload)
        """;

    private const string InsertIdempotencySql = """
        INSERT INTO http_idempotency_keys (user_id, idempotency_key, operation, request_sha256, status_code, response_body)
        VALUES (@userId, @key, @operation, @requestSha256, 201, CAST(@responseBody AS jsonb))
        """;

    public async Task<StoredIdempotentResponse?> FindIdempotentResponseAsync(Guid userId, Guid key, CancellationToken cancellationToken)
    {
        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        return await connection.QuerySingleOrDefaultAsync<StoredIdempotentResponse>(new CommandDefinition(
            FindIdempotentSql, new { userId, key }, cancellationToken: cancellationToken)).ConfigureAwait(false);
    }

    public async Task<PlanWriteStatus> CreateAsync(
        Guid userId, TrainingPlan plan, IdempotencyRequest idempotency, string responseBody, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(idempotency);

        var workouts = plan.Workouts;
        var exercises = workouts.SelectMany(w => w.Exercises.Select(e => (WorkoutId: w.Id, Exercise: e))).ToArray();
        var changes = new List<Change>(1 + workouts.Count + exercises.Length)
        {
            new("training_plan", plan.Id, plan.Version, PlanPayload(plan)),
        };
        changes.AddRange(workouts.Select(w => new Change("planned_workout", w.Id, 1, WorkoutPayload(plan.Id, w))));
        changes.AddRange(exercises.Select(e => new Change("planned_exercise", e.Exercise.Id, 1, ExercisePayload(e.WorkoutId, e.Exercise))));

        await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var userExists = await connection.ExecuteScalarAsync<int?>(new CommandDefinition(
                LockUserSql, new { userId }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
            if (userExists is null)
            {
                return PlanWriteStatus.UserNotFound;
            }

            await connection.ExecuteAsync(new CommandDefinition(
                EnsureSyncStateSql, new { userId }, transaction, cancellationToken: cancellationToken)).ConfigureAwait(false);
            var lastSeq = await connection.ExecuteScalarAsync<long>(new CommandDefinition(
                AdvanceSeqSql, new { userId, count = (long)changes.Count }, transaction, cancellationToken: cancellationToken))
                .ConfigureAwait(false);

            await connection.ExecuteAsync(new CommandDefinition(
                InsertPlanSql,
                new
                {
                    id = plan.Id,
                    userId,
                    title = plan.Title,
                    revision = plan.Revision,
                    parentPlanId = plan.ParentPlanId,
                    status = plan.Status,
                    version = plan.Version,
                    lineageId = plan.LineageId,
                    kind = plan.Kind,
                    eventDate = plan.EventDate?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                    eventName = plan.EventName,
                    primaryDiscipline = plan.PrimaryDiscipline,
                },
                transaction,
                cancellationToken: cancellationToken)).ConfigureAwait(false);

            if (workouts.Count > 0)
            {
                await connection.ExecuteAsync(new CommandDefinition(
                    InsertWorkoutsSql,
                    new
                    {
                        userId,
                        planId = plan.Id,
                        ids = workouts.Select(w => w.Id).ToArray(),
                        weekdays = workouts.Select(w => w.Weekday).ToArray(),
                        titles = workouts.Select(w => w.Title).ToArray(),
                        orderIndexes = workouts.Select(w => w.OrderIndex).ToArray(),
                    },
                    transaction,
                    cancellationToken: cancellationToken)).ConfigureAwait(false);
            }

            if (exercises.Length > 0)
            {
                await connection.ExecuteAsync(new CommandDefinition(
                    InsertExercisesSql,
                    new
                    {
                        userId,
                        ids = exercises.Select(e => e.Exercise.Id).ToArray(),
                        workoutIds = exercises.Select(e => e.WorkoutId).ToArray(),
                        exerciseIds = exercises.Select(e => e.Exercise.ExerciseId).ToArray(),
                        orderIndexes = exercises.Select(e => e.Exercise.OrderIndex).ToArray(),
                        setCounts = exercises.Select(e => e.Exercise.SetCount).ToArray(),
                        targets = exercises.Select(e => e.Exercise.Target.GetRawText()).ToArray(),
                        restSeconds = exercises.Select(e => e.Exercise.RestSeconds).ToArray(),
                    },
                    transaction,
                    cancellationToken: cancellationToken)).ConfigureAwait(false);
            }

            var firstSeq = lastSeq - changes.Count + 1;
            await connection.ExecuteAsync(new CommandDefinition(
                InsertChangesSql,
                new
                {
                    userId,
                    seqs = changes.Select((_, i) => firstSeq + i).ToArray(),
                    entityTypes = changes.Select(c => c.EntityType).ToArray(),
                    entityIds = changes.Select(c => c.EntityId).ToArray(),
                    serverVersions = changes.Select(c => c.ServerVersion).ToArray(),
                    payloads = changes.Select(c => c.Payload).ToArray(),
                },
                transaction,
                cancellationToken: cancellationToken)).ConfigureAwait(false);

            await connection.ExecuteAsync(new CommandDefinition(
                InsertIdempotencySql,
                new { userId, key = idempotency.Key, operation = idempotency.Operation, requestSha256 = idempotency.RequestSha256, responseBody },
                transaction,
                cancellationToken: cancellationToken)).ConfigureAwait(false);

            await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
            return PlanWriteStatus.Created;
        }
        catch (PostgresException e) when (e.SqlState is PlanCountLimitSqlState or PostgresErrorCodes.UniqueViolation or PostgresErrorCodes.ForeignKeyViolation)
        {
            // The transaction is rolled back on dispose; nothing from this request is kept.
            return e.SqlState switch
            {
                PlanCountLimitSqlState => PlanWriteStatus.PlanCountLimit,
                PostgresErrorCodes.UniqueViolation => PlanWriteStatus.UniqueViolation,
                _ => PlanWriteStatus.ForeignKeyViolation,
            };
        }
    }

    private sealed record Change(string EntityType, Guid EntityId, long ServerVersion, string Payload);

    // contracts/entity-payloads.schema.json training_plan_payload; null optionals are omitted.
    private static string PlanPayload(TrainingPlan plan)
    {
        var payload = new JsonObject
        {
            ["id"] = plan.Id,
            ["title"] = plan.Title,
            ["revision"] = plan.Revision,
            ["status"] = plan.Status,
            ["lineageId"] = plan.LineageId,
            ["kind"] = plan.Kind,
            ["primaryDiscipline"] = plan.PrimaryDiscipline,
        };
        if (plan.ParentPlanId is { } parent)
        {
            payload["parentPlanId"] = parent;
        }

        if (plan.EventDate is { } eventDate)
        {
            payload["eventDate"] = eventDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        }

        if (plan.EventName is { } eventName)
        {
            payload["eventName"] = eventName;
        }

        return payload.ToJsonString();
    }

    // planned_workout_payload
    private static string WorkoutPayload(Guid planId, PlannedWorkout workout) => new JsonObject
    {
        ["id"] = workout.Id,
        ["planId"] = planId,
        ["weekday"] = workout.Weekday,
        ["title"] = workout.Title,
        ["orderIndex"] = workout.OrderIndex,
    }.ToJsonString();

    // planned_exercise_payload
    private static string ExercisePayload(Guid workoutId, PlannedExercise exercise) => new JsonObject
    {
        ["id"] = exercise.Id,
        ["plannedWorkoutId"] = workoutId,
        ["exerciseId"] = exercise.ExerciseId,
        ["orderIndex"] = exercise.OrderIndex,
        ["setCount"] = exercise.SetCount,
        ["target"] = JsonNode.Parse(exercise.Target.GetRawText()),
        ["restSeconds"] = exercise.RestSeconds,
    }.ToJsonString();
}
