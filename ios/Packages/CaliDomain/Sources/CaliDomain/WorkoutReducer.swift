import Foundation

/// Pure, deterministic workout reducer (docs/03 §4, §6). No I/O, no clocks, no timers.
///
/// Usage by the coordinator (docs/03 §6): inside one transaction, dedupe `commandId`, load state,
/// call `reduce`, persist `transition.state` with `expectedRevision = state.revision`, persist
/// `transition.setRecords` + outbox, record the processed command, commit, then run side effects
/// driven by `transition.events`.
public enum WorkoutReducer {

    // MARK: Entry points

    /// Reduce with an optional current session (`nil` = no session row loaded). Only `CreateSession`
    /// is accepted without a session.
    public static func reduce(_ state: SessionState?, _ command: Command, now: Date) -> Result<Transition, DomainError> {
        if case .createSession(let c) = command { return createSession(c, existing: state, now: now) }
        guard let state else { return .failure(.noSession) }
        return reduce(state, command, now: now)
    }

    public static func reduce(_ state: SessionState, _ command: Command, now: Date) -> Result<Transition, DomainError> {
        if case .createSession(let c) = command { return createSession(c, existing: state, now: now) }
        guard state.status == .active else { return .failure(.sessionNotActive(state.status)) }

        switch command {
        case .createSession:
            preconditionFailure("handled above")
        case .startSet(let c):
            return startSet(state, c, now: now)
        case .pause:
            return pause(state, now: now)
        case .resume:
            return resume(state, now: now)
        case .stopSet:
            return stopSet(state, now: now)
        case .confirmSet(let c):
            return confirmSet(state, c, now: now)
        case .extendRest(let c):
            return extendRest(state, c, now: now)
        case .readyNext:
            return readyNext(state, now: now)
        case .skipSet(let c):
            return skipSet(state, c, now: now)
        case .finishSession:
            return finishSession(state, now: now)
        case .abandonSession(let c):
            return abandonSession(state, c, now: now)
        }
    }

    // MARK: Commands

    static func createSession(_ c: CreateSession, existing: SessionState?, now: Date) -> Result<Transition, DomainError> {
        if let existing, existing.status == .active {
            return .failure(.activeSessionExists(sessionId: existing.sessionId))
        }
        var issues: [ValidationIssue] = []
        if c.executions.isEmpty {
            issues.append(ValidationIssue(field: "executions", reason: .missing, detail: "at least one exercise required"))
        }
        if c.executions.count > DomainLimits.maxExecutionsPerSession {
            issues.append(ValidationIssue(field: "executions", reason: .outOfRange, detail: "\(c.executions.count) > \(DomainLimits.maxExecutionsPerSession)"))
        }
        if Set(c.executions.map(\.id)).count != c.executions.count {
            issues.append(ValidationIssue(field: "executions.id", reason: .duplicate, detail: "execution ids must be unique"))
        }
        for (i, spec) in c.executions.enumerated() {
            issues.append(contentsOf: spec.validate().map {
                ValidationIssue(field: "executions[\(i)].\($0.field)", reason: $0.reason, detail: $0.detail)
            })
        }
        guard issues.isEmpty else { return .failure(.validationFailed(issues)) }

        let state = SessionState(
            sessionId: c.sessionId,
            plannedWorkoutId: c.plannedWorkoutId,
            status: .active,
            phase: .ready,
            revision: 1,
            executions: c.executions,
            currentExecutionIndex: 0,
            currentSetIndex: 1,
            startedAt: now,
            updatedAt: now,
            phaseStartedAt: now
        )
        return .success(Transition(state: state, events: [.sessionCreated(sessionId: c.sessionId, startedAt: now)]))
    }

    static func startSet(_ s: SessionState, _ c: StartSet, now: Date) -> Result<Transition, DomainError> {
        guard s.phase == .ready else { return .failure(.invalidTransition(from: s.phase, command: .startSet)) }
        guard let key = s.currentSetKey else { return .failure(.invalidTransition(from: s.phase, command: .startSet)) }
        if let existing = s.resolution(for: key) { return .failure(.duplicateSetResolution(existing: existing)) }
        if let issue = ValidationIssue.range("countdownSeconds", c.countdownSeconds, DomainLimits.countdownSeconds) {
            return .failure(.validationFailed([issue]))
        }
        var b = Builder(s)
        if c.countdownSeconds == 0 {
            // Countdown disabled in Settings (UX §5): explicit user input starts exercising directly.
            b.beginExercising(at: now)
        } else {
            b.next.phase = .preCountdown
            b.next.phaseStartedAt = now
            b.next.phaseDeadlineAt = TimeMath.date(now, plusSeconds: c.countdownSeconds)
            b.next.countdownSeconds = c.countdownSeconds
        }
        return .success(b.commit(now: now))
    }

    static func pause(_ s: SessionState, now: Date) -> Result<Transition, DomainError> {
        guard s.phase == .exercising else { return .failure(.invalidTransition(from: s.phase, command: .pause)) }
        var b = Builder(s)
        let segment = max(0, s.phaseStartedAt.map { TimeMath.ms(from: $0, to: now) } ?? 0)
        b.next.accumulatedExerciseMs = s.accumulatedExerciseMs + segment
        if let deadline = s.phaseDeadlineAt, let target = s.currentExecution?.target.targetDurationSeconds {
            // Freeze remaining time; clamp to [0, target] so a clock anomaly can never inflate it.
            let remaining = TimeMath.ms(from: now, to: deadline)
            b.next.pausedRemainingMs = min(max(0, remaining), TimeMath.ms(seconds: target))
        }
        b.next.phase = .paused
        b.next.pausedAt = now
        b.next.phaseStartedAt = now
        b.next.phaseDeadlineAt = nil // PAUSED has no moving deadline (docs/03 §4)
        return .success(b.commit(now: now))
    }

    static func resume(_ s: SessionState, now: Date) -> Result<Transition, DomainError> {
        guard s.phase == .paused else { return .failure(.invalidTransition(from: s.phase, command: .resume)) }
        var b = Builder(s)
        b.next.phase = .exercising
        b.next.phaseStartedAt = now
        // Recompute from the frozen remaining time instead of adding timers.
        b.next.phaseDeadlineAt = s.pausedRemainingMs.map { TimeMath.date(now, plusMs: $0) }
        b.next.pausedAt = nil
        b.next.pausedRemainingMs = nil
        return .success(b.commit(now: now))
    }

    static func stopSet(_ s: SessionState, now: Date) -> Result<Transition, DomainError> {
        guard s.phase == .exercising, let key = s.currentSetKey else {
            return .failure(.invalidTransition(from: s.phase, command: .stopSet))
        }
        let raw = s.accumulatedExerciseMs + (s.phaseStartedAt.map { TimeMath.ms(from: $0, to: now) } ?? 0)
        var b = Builder(s)
        b.enterAwaitingResult(
            ResultDraft(
                key: key,
                measuredElapsedMs: max(0, raw),
                // Negative ⇒ wall clock went backwards; do not invent a duration (docs/03 §5).
                suggestedActualMs: raw >= 0 ? raw : nil,
                endReason: .userStopped
            ),
            now: now
        )
        return .success(b.commit(now: now))
    }

    static func confirmSet(_ s: SessionState, _ c: ConfirmSet, now: Date) -> Result<Transition, DomainError> {
        // Duplicate check first, in any active phase: a double tap arrives after the phase already advanced.
        if let existing = s.resolution(for: c.key) { return .failure(.duplicateSetResolution(existing: existing)) }
        guard s.phase == .awaitingResult, let draft = s.pendingResult, let spec = s.currentExecution else {
            return .failure(.invalidTransition(from: s.phase, command: .confirmSet))
        }
        guard c.key == draft.key else { return .failure(.setMismatch(expected: draft.key, received: c.key)) }
        let issues = validateActuals(c, for: spec.target)
        guard issues.isEmpty else { return .failure(.validationFailed(issues)) }

        let record = SetRecord(
            setResultId: c.setResultId,
            sessionId: s.sessionId,
            key: c.key,
            status: c.status,
            prescribed: PrescribedSnapshot(spec),
            actual: SetActuals(reps: c.actualReps, holdMs: c.actualHoldMs, workMs: c.actualWorkMs, restMs: c.actualRestMs, rpe: c.rpe, note: c.note),
            endReason: draft.endReason,
            skipReason: nil,
            confirmedAt: now,
            revision: 1
        )
        var b = Builder(s)
        b.next.resolvedSets.append(ResolvedSet(key: c.key, setResultId: c.setResultId, status: c.status))
        b.events.append(.setConfirmed(record))
        b.advanceAfterResolution(restBeforeNextSet: true, now: now)
        return .success(b.commit(now: now))
    }

    static func extendRest(_ s: SessionState, _ c: ExtendRest, now: Date) -> Result<Transition, DomainError> {
        guard s.phase == .resting, let deadline = s.phaseDeadlineAt else {
            return .failure(.invalidTransition(from: s.phase, command: .extendRest))
        }
        if let issue = ValidationIssue.range("seconds", c.seconds, DomainLimits.restExtensionSeconds) {
            return .failure(.validationFailed([issue]))
        }
        // Extend from the later of the current deadline and now (an overdue rest gets +N from now).
        let base = max(deadline, now)
        let newDeadline = TimeMath.date(base, plusSeconds: c.seconds)
        if TimeMath.ms(from: now, to: newDeadline) > TimeMath.ms(seconds: DomainLimits.maxRemainingRestSeconds) {
            return .failure(.validationFailed([ValidationIssue(field: "seconds", reason: .outOfRange, detail: "remaining rest would exceed \(DomainLimits.maxRemainingRestSeconds)s")]))
        }
        var b = Builder(s)
        b.next.phaseDeadlineAt = newDeadline
        return .success(b.commit(now: now))
    }

    static func readyNext(_ s: SessionState, now: Date) -> Result<Transition, DomainError> {
        guard s.phase == .resting else { return .failure(.invalidTransition(from: s.phase, command: .readyNext)) }
        var b = Builder(s)
        b.enterReady(now: now)
        return .success(b.commit(now: now))
    }

    static func skipSet(_ s: SessionState, _ c: SkipSet, now: Date) -> Result<Transition, DomainError> {
        if let existing = s.resolution(for: c.key) { return .failure(.duplicateSetResolution(existing: existing)) }
        guard [.ready, .exercising, .awaitingResult].contains(s.phase), let key = s.currentSetKey, let spec = s.currentExecution else {
            return .failure(.invalidTransition(from: s.phase, command: .skipSet))
        }
        guard c.key == key else { return .failure(.setMismatch(expected: key, received: c.key)) }
        if let issue = validateReason(c.reason, field: "reason") { return .failure(.validationFailed([issue])) }

        let endReason: SetEndReason? = switch s.phase {
        case .exercising: .userStopped
        case .awaitingResult: s.pendingResult?.endReason
        default: nil
        }
        let record = SetRecord(
            setResultId: c.setResultId,
            sessionId: s.sessionId,
            key: key,
            status: .skipped,
            prescribed: PrescribedSnapshot(spec),
            actual: .none,
            endReason: endReason,
            skipReason: c.reason,
            confirmedAt: now,
            revision: 1
        )
        var b = Builder(s)
        b.next.resolvedSets.append(ResolvedSet(key: key, setResultId: c.setResultId, status: .skipped))
        b.events.append(.setSkipped(record))
        // Interpretation (CON-002 Q4): a skipped set does not earn a rest; go to the next set's READY.
        b.advanceAfterResolution(restBeforeNextSet: false, now: now)
        return .success(b.commit(now: now))
    }

    static func finishSession(_ s: SessionState, now: Date) -> Result<Transition, DomainError> {
        guard s.phase == .reviewingSummary, s.pendingResult == nil, s.allSetsResolved else {
            return .failure(.invalidTransition(from: s.phase, command: .finishSession))
        }
        guard now >= s.startedAt else { return .failure(.timestampBeforeSessionStart) }
        var b = Builder(s)
        b.next.status = .completed
        b.next.phase = .completed
        b.next.finishedAt = now
        b.next.phaseStartedAt = now
        b.events.append(.sessionFinished(finishedAt: now))
        return .success(b.commit(now: now))
    }

    static func abandonSession(_ s: SessionState, _ c: AbandonSession, now: Date) -> Result<Transition, DomainError> {
        // Interpretation (CON-002 Q1): table precondition "active session" — allowed from every
        // non-terminal phase, including preCountdown/exercising which the diagram omits.
        if let issue = validateReason(c.reason, field: "reason") { return .failure(.validationFailed([issue])) }
        var b = Builder(s)
        b.clearSetScratch()
        b.next.status = .abandoned
        b.next.phase = .abandoned
        b.next.abandonedAt = now
        b.next.abandonReason = c.reason
        b.next.phaseStartedAt = now
        b.next.phaseDeadlineAt = nil
        b.events.append(.sessionAbandoned(at: now, reason: c.reason))
        return .success(b.commit(now: now))
    }

    // MARK: Validation helpers

    static func validateActuals(_ c: ConfirmSet, for target: Prescription) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if c.status == .skipped {
            issues.append(ValidationIssue(field: "status", reason: .notAllowed, detail: "use skip_set for skipped sets"))
        }
        if let v = c.actualReps, let i = ValidationIssue.min("actualReps", v, 0) { issues.append(i) }
        if let v = c.actualHoldMs, let i = ValidationIssue.min("actualHoldMs", v, 0) { issues.append(i) }
        if let v = c.actualWorkMs, let i = ValidationIssue.min("actualWorkMs", v, 0) { issues.append(i) }
        if let v = c.actualRestMs, let i = ValidationIssue.min("actualRestMs", v, 0) { issues.append(i) }
        if let v = c.rpe, let i = ValidationIssue.range("rpe", v, DomainLimits.rpe) { issues.append(i) }

        func require(_ present: Bool, _ field: String) {
            if !present { issues.append(ValidationIssue(field: field, reason: .missing, detail: "required for \(target.type.rawValue)")) }
        }
        // Primary actual metric per type (docs/03 §3 "Actual output").
        switch target {
        case .staticHold: require(c.actualHoldMs != nil, "actualHoldMs")
        case .reps: require(c.actualReps != nil, "actualReps")
        case .timedReps:
            require(c.actualReps != nil, "actualReps")
            require(c.actualWorkMs != nil, "actualWorkMs")
        case .interval: require(c.actualWorkMs != nil, "actualWorkMs")
        case .skillAttempt: break // success/fail is `status`; hold optional
        }
        return issues
    }

    static func validateReason(_ reason: String?, field: String) -> ValidationIssue? {
        guard let reason, reason.count > DomainLimits.maxReasonLength else { return nil }
        return ValidationIssue(field: field, reason: .outOfRange, detail: "length \(reason.count) > \(DomainLimits.maxReasonLength)")
    }
}

// MARK: - Transition builder

/// Accumulates one transition: mutates a copy, collects explicit events, then appends derived
/// `phaseChanged` / `deadlineChanged` events and bumps the revision exactly once.
struct Builder {
    let previous: SessionState
    var next: SessionState
    var events: [DomainEvent] = []

    init(_ state: SessionState) {
        previous = state
        next = state
    }

    mutating func commit(now: Date) -> Transition {
        next.revision = previous.revision + 1
        next.updatedAt = now
        if previous.phase != next.phase {
            events.append(.phaseChanged(from: previous.phase, to: next.phase))
        }
        if previous.phaseDeadlineAt != next.phaseDeadlineAt {
            events.append(.deadlineChanged(phase: next.phase, deadline: next.phaseDeadlineAt))
        }
        return Transition(state: next, events: events)
    }

    mutating func clearSetScratch() {
        next.countdownSeconds = nil
        next.accumulatedExerciseMs = 0
        next.pausedAt = nil
        next.pausedRemainingMs = nil
        next.pendingResult = nil
    }

    mutating func beginExercising(at start: Date) {
        clearSetScratch()
        next.phase = .exercising
        next.phaseStartedAt = start
        next.phaseDeadlineAt = next.currentExecution?.target.targetDurationSeconds.map { TimeMath.date(start, plusSeconds: $0) }
    }

    mutating func enterAwaitingResult(_ draft: ResultDraft, now: Date) {
        clearSetScratch()
        next.phase = .awaitingResult
        next.phaseStartedAt = now
        next.phaseDeadlineAt = nil
        next.pendingResult = draft
    }

    mutating func enterReady(now: Date) {
        clearSetScratch()
        next.phase = .ready
        next.phaseStartedAt = now
        next.phaseDeadlineAt = nil
    }

    /// After a set is confirmed or skipped: next set (rest or ready), next exercise (ready), or summary.
    mutating func advanceAfterResolution(restBeforeNextSet: Bool, now: Date) {
        clearSetScratch()
        guard let spec = next.currentExecution else { return }
        if next.currentSetIndex < spec.setCount {
            next.currentSetIndex += 1
            if restBeforeNextSet {
                next.phase = .resting
                next.phaseStartedAt = now
                // restSeconds == 0 ⇒ deadline == now; the next reconcile marks it ready (CON-002 Q5).
                next.phaseDeadlineAt = TimeMath.date(now, plusSeconds: spec.restSeconds)
            } else {
                enterReady(now: now)
            }
        } else if next.currentExecutionIndex + 1 < next.executions.count {
            next.currentExecutionIndex += 1
            next.currentSetIndex = 1
            enterReady(now: now)
        } else {
            // Final set: summary while status stays active; only FinishSession completes.
            next.phase = .reviewingSummary
            next.phaseStartedAt = now
            next.phaseDeadlineAt = nil
        }
    }
}
