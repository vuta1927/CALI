import CaliDomain
import Foundation

/// IOS-007: the wire form of local entities, `contracts/entity-payloads.schema.json` (closed objects, ADR-030).
/// Built once when the mutation is queued and stored as is: a payload is never changed after an HTTP attempt
/// has started (docs/08 §3). Optional fields are omitted when nil, which the schema allows.
enum SyncPayloads {
    struct WorkoutSession: Encodable {
        var id: UUID
        var plannedWorkoutId: UUID?
        var localDate: String
        var timezone: String
        var status: SessionStatus
        var phase: Phase
        var startedAt: Date
        var finishedAt: Date?
        var phaseStartedAt: Date?
        var phaseDeadlineAt: Date?
        var currentExecutionId: UUID?
        var currentSetIndex: Int?
        var pausedAt: Date?
        var accumulatedExerciseMs: Int64?
        var abandonReason: String?

        init(_ s: SessionState, localDate: String, timezone: String) {
            id = s.sessionId
            plannedWorkoutId = s.plannedWorkoutId
            self.localDate = localDate
            self.timezone = timezone
            status = s.status
            phase = s.phase
            startedAt = s.startedAt
            finishedAt = s.finishedAt ?? s.abandonedAt
            phaseStartedAt = s.phaseStartedAt
            phaseDeadlineAt = s.phaseDeadlineAt
            let current = s.executions.indices.contains(s.currentExecutionIndex) ? s.executions[s.currentExecutionIndex] : nil
            currentExecutionId = s.phase.isTerminal ? nil : current?.id
            currentSetIndex = s.phase.isTerminal ? nil : s.currentSetIndex
            pausedAt = s.phase == .paused ? s.pausedAt : nil
            accumulatedExerciseMs = s.accumulatedExerciseMs
            abandonReason = s.abandonReason
        }
    }

    struct ExerciseExecution: Encodable {
        var id: UUID
        var sessionId: UUID
        var plannedExerciseId: UUID?
        var exerciseId: UUID
        var orderIndex: Int
        var prescribedSnapshot: PrescribedSnapshot

        init(sessionId: UUID, spec: ExecutionSpec, orderIndex: Int) {
            id = spec.id
            self.sessionId = sessionId
            plannedExerciseId = spec.plannedExerciseId
            exerciseId = spec.exerciseId
            self.orderIndex = orderIndex
            prescribedSnapshot = PrescribedSnapshot(spec)
        }
    }

    struct SetResult: Encodable {
        var id: UUID
        var executionId: UUID
        var setIndex: Int
        var status: SetStatus
        var prescribedSnapshot: PrescribedSnapshot
        var actualReps: Int?
        var actualHoldMs: Int64?
        var actualWorkMs: Int64?
        var actualRestMs: Int64?
        var distanceMeters: Int?
        var durationSeconds: Int?
        var source: ResultSource?
        var actualLoadKg: Decimal?
        var rpe: Int?
        var note: String?
        var skipReason: String?
        var painReported: Bool?
        var confirmedAt: Date
        var revision: Int
        var criteriaVersion: Int?
        var criteria: [String: CriteriaValue]?

        init(_ r: SetRecord) {
            id = r.setResultId
            executionId = r.key.executionId
            setIndex = r.key.setIndex
            status = r.status
            prescribedSnapshot = r.prescribed
            actualReps = r.actual.reps
            actualHoldMs = r.actual.holdMs
            actualWorkMs = r.actual.workMs
            actualRestMs = r.actual.restMs
            distanceMeters = r.actual.distanceMeters
            durationSeconds = r.actual.durationSeconds
            source = r.actual.source
            actualLoadKg = r.actual.loadKg
            rpe = r.actual.rpe
            note = r.actual.note
            skipReason = r.skipReason
            painReported = r.actual.painReported
            confirmedAt = r.confirmedAt
            revision = r.revision
            criteriaVersion = r.actual.criteriaVersion
            criteria = r.actual.criteria
        }
    }

    /// `workout_session.localDate`: the calendar date of `startedAt` in the zone the session started in.
    static func localDate(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}
