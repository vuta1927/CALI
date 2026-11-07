import Foundation

/// Identity of one planned set inside a session. `setIndex` is 1-based (contract `setIndex >= 1`).
public struct SetKey: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public var executionId: UUID
    public var setIndex: Int

    public init(executionId: UUID, setIndex: Int) {
        self.executionId = executionId
        self.setIndex = setIndex
    }

    public var description: String { "\(executionId.uuidString)#\(setIndex)" }
}

/// A set that already has a canonical result (confirmed or skipped). Used to enforce
/// "exactly one result per (executionId, setIndex)" (docs/03 §4, docs/07 §3).
public struct ResolvedSet: Codable, Equatable, Hashable, Sendable {
    public var key: SetKey
    public var setResultId: UUID
    public var status: SetStatus

    public init(key: SetKey, setResultId: UUID, status: SetStatus) {
        self.key = key
        self.setResultId = setResultId
        self.status = status
    }
}

/// Why the exercising phase ended and the session is awaiting the user's actual values.
public enum SetEndReason: Codable, Equatable, Hashable, Sendable {
    /// Explicit `StopSet`.
    case userStopped
    /// The target deadline was found elapsed by `reconcile` (`targetDeadlineReached`).
    /// `lateMs` = how long after the deadline the reconcile ran (large ⇒ app was likely suspended).
    case targetDeadlineReached(lateMs: Int64)
}

/// Draft shown in the result form. It is *not* a set result: nothing is counted until `ConfirmSet` (ADR-009).
public struct ResultDraft: Codable, Equatable, Hashable, Sendable {
    public var key: SetKey
    /// Exercising time measured by the domain (sum of running segments), clamped at 0.
    public var measuredElapsedMs: Int64
    /// Pre-fill for the editable actual duration, or `nil` when the domain cannot know it
    /// (deadline reconciled late after suspension, or clock went backwards) — the user must enter it.
    public var suggestedActualMs: Int64?
    public var endReason: SetEndReason

    public init(key: SetKey, measuredElapsedMs: Int64, suggestedActualMs: Int64?, endReason: SetEndReason) {
        self.key = key
        self.measuredElapsedMs = measuredElapsedMs
        self.suggestedActualMs = suggestedActualMs
        self.endReason = endReason
    }
}

/// Authoritative, persistable state of one workout session. Pure value; the reducer returns a new copy.
///
/// Timer fields are UTC `Date`s persisted with the revision (docs/03 §4): the UI may render a countdown
/// from `phaseDeadlineAt` without per-second writes.
public struct SessionState: Codable, Equatable, Sendable {
    public var sessionId: UUID
    public var plannedWorkoutId: UUID?
    public var status: SessionStatus
    public var phase: Phase
    /// Increments by exactly 1 on every accepted transition (command or reconcile step).
    public var revision: Int
    /// Linear exercise sequence (MVP: no supersets).
    public var executions: [ExecutionSpec]
    /// 0-based index into `executions`.
    public var currentExecutionIndex: Int
    /// 1-based set index within the current execution.
    public var currentSetIndex: Int

    public var startedAt: Date
    /// `now` of the last accepted transition; used for clock-jump and stale-session detection.
    public var updatedAt: Date
    public var finishedAt: Date?
    public var abandonedAt: Date?
    public var abandonReason: String?

    /// Start of the current phase. While `exercising` it is the start of the current *running segment*.
    public var phaseStartedAt: Date?
    /// UTC deadline of the current phase. Non-nil only in `preCountdown`, `resting`, and timed `exercising`.
    public var phaseDeadlineAt: Date?
    /// Countdown length requested by `StartSet` (only in `preCountdown`).
    public var countdownSeconds: Int?
    /// Exercising time accumulated by earlier running segments of the current set (pause/resume).
    public var accumulatedExerciseMs: Int64
    /// Set only while `paused`.
    public var pausedAt: Date?
    /// Remaining target time captured at pause (only while `paused` and the set is timed).
    public var pausedRemainingMs: Int64?
    /// Set only while `awaitingResult`.
    public var pendingResult: ResultDraft?
    /// Sets that already have a canonical result.
    public var resolvedSets: [ResolvedSet]

    public init(
        sessionId: UUID,
        plannedWorkoutId: UUID?,
        status: SessionStatus,
        phase: Phase,
        revision: Int,
        executions: [ExecutionSpec],
        currentExecutionIndex: Int,
        currentSetIndex: Int,
        startedAt: Date,
        updatedAt: Date,
        finishedAt: Date? = nil,
        abandonedAt: Date? = nil,
        abandonReason: String? = nil,
        phaseStartedAt: Date? = nil,
        phaseDeadlineAt: Date? = nil,
        countdownSeconds: Int? = nil,
        accumulatedExerciseMs: Int64 = 0,
        pausedAt: Date? = nil,
        pausedRemainingMs: Int64? = nil,
        pendingResult: ResultDraft? = nil,
        resolvedSets: [ResolvedSet] = []
    ) {
        self.sessionId = sessionId
        self.plannedWorkoutId = plannedWorkoutId
        self.status = status
        self.phase = phase
        self.revision = revision
        self.executions = executions
        self.currentExecutionIndex = currentExecutionIndex
        self.currentSetIndex = currentSetIndex
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.abandonedAt = abandonedAt
        self.abandonReason = abandonReason
        self.phaseStartedAt = phaseStartedAt
        self.phaseDeadlineAt = phaseDeadlineAt
        self.countdownSeconds = countdownSeconds
        self.accumulatedExerciseMs = accumulatedExerciseMs
        self.pausedAt = pausedAt
        self.pausedRemainingMs = pausedRemainingMs
        self.pendingResult = pendingResult
        self.resolvedSets = resolvedSets
    }

    // MARK: Derived

    public var isActive: Bool { status == .active }

    public var currentExecution: ExecutionSpec? {
        executions.indices.contains(currentExecutionIndex) ? executions[currentExecutionIndex] : nil
    }

    public var currentSetKey: SetKey? {
        currentExecution.map { SetKey(executionId: $0.id, setIndex: currentSetIndex) }
    }

    public func resolution(for key: SetKey) -> ResolvedSet? {
        resolvedSets.first { $0.key == key }
    }

    public var totalPlannedSets: Int { executions.reduce(0) { $0 + $1.setCount } }
    public var confirmedSetCount: Int { resolvedSets.filter { $0.status != .skipped }.count }
    public var skippedSetCount: Int { resolvedSets.filter { $0.status == .skipped }.count }
    public var allSetsResolved: Bool { resolvedSets.count == totalPlannedSets }

    /// Exercising time of the current set at `now` (accumulated + current running segment), clamped at 0.
    public func exerciseElapsedMs(at now: Date) -> Int64 {
        switch phase {
        case .exercising:
            let segment = phaseStartedAt.map { TimeMath.ms(from: $0, to: now) } ?? 0
            return max(0, accumulatedExerciseMs + segment)
        case .paused:
            return accumulatedExerciseMs
        default:
            return 0
        }
    }

    /// Remaining time of the current phase at `now` (milliseconds, may be negative when overdue),
    /// or `nil` when the phase has no deadline. While `paused` returns the frozen remaining time.
    public func remainingMs(at now: Date) -> Int64? {
        if phase == .paused { return pausedRemainingMs }
        return phaseDeadlineAt.map { TimeMath.ms(from: now, to: $0) }
    }

    /// Structural invariants that must hold after every accepted transition. Empty == consistent.
    /// Exposed so CaliCore can assert on load/save and tests can check every reducer output.
    public var invariantViolations: [String] {
        var v: [String] = []
        if revision < 1 { v.append("revision < 1") }
        if executions.isEmpty { v.append("no executions") }
        if Set(resolvedSets.map(\.key)).count != resolvedSets.count { v.append("duplicate resolved set key") }
        if resolvedSets.count > totalPlannedSets { v.append("more resolved sets than planned") }
        switch status {
        case .active:
            if phase.isTerminal { v.append("active status with terminal phase") }
            if finishedAt != nil { v.append("active session has finishedAt") }
        case .completed:
            if phase != .completed { v.append("completed status requires completed phase") }
            if finishedAt == nil { v.append("completed session without finishedAt") }
            if !allSetsResolved { v.append("completed session with unresolved sets") }
        case .abandoned:
            if phase != .abandoned { v.append("abandoned status requires abandoned phase") }
            if abandonedAt == nil { v.append("abandoned session without abandonedAt") }
        }
        if let f = finishedAt, f < startedAt { v.append("finishedAt < startedAt") }
        switch phase {
        case .preCountdown:
            if phaseDeadlineAt == nil { v.append("preCountdown without deadline") }
        case .exercising:
            let timed = currentExecution?.target.targetDurationSeconds != nil
            if timed != (phaseDeadlineAt != nil) { v.append("exercising deadline must exist iff target is timed") }
        case .paused:
            if phaseDeadlineAt != nil { v.append("paused must not have a moving deadline") }
            if pausedAt == nil { v.append("paused without pausedAt") }
        case .awaitingResult:
            if pendingResult == nil { v.append("awaitingResult without draft") }
            if phaseDeadlineAt != nil { v.append("awaitingResult must not have a deadline") }
        case .resting:
            if phaseDeadlineAt == nil { v.append("resting without deadline") }
        case .ready, .reviewingSummary, .completed, .abandoned:
            if phaseDeadlineAt != nil { v.append("\(phase.rawValue) must not have a deadline") }
        }
        if phase != .paused, pausedAt != nil || pausedRemainingMs != nil { v.append("pause fields outside paused") }
        if phase != .awaitingResult, pendingResult != nil { v.append("draft outside awaitingResult") }
        if phase == .reviewingSummary, !allSetsResolved { v.append("reviewingSummary with unresolved sets") }
        if status == .active, phase != .reviewingSummary, let key = currentSetKey, resolution(for: key) != nil {
            v.append("current set \(key) is already resolved")
        }
        return v
    }
}
