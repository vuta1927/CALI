import Foundation

/// Tolerances for `WorkoutReducer.reconcile`. All values are product-tunable (CON-002 Q9/Q10).
public struct ReconcilePolicy: Equatable, Sendable {
    /// A pre-countdown found elapsed by at most this much counts as "elapsed while foreground"
    /// and starts exercising at the countdown deadline. Later ⇒ the app was not executing ⇒ back to READY.
    public var countdownLateTolerance: TimeInterval
    /// A timed-set deadline reconciled within this window pre-fills the target as suggested actual.
    /// Later ⇒ the user may have stopped while locked ⇒ no suggestion, ask for actual (docs/03 §5).
    public var promptDeadlineTolerance: TimeInterval
    /// Wall clock earlier than the previous reading / last transition by more than this ⇒ backward jump.
    public var backwardJumpTolerance: TimeInterval
    /// |wall elapsed − monotonic elapsed| above this ⇒ clock changed while the process was running.
    public var monotonicDriftTolerance: TimeInterval
    /// Without a monotonic reading, a forward gap above this since `previousNow` is treated as a jump
    /// needing user reconciliation. `nil` disables the check.
    public var forwardGapThreshold: TimeInterval?
    /// Session untouched for this long ⇒ ask the user to resume/finish/abandon (docs/03 §7 #7).
    public var staleSessionThreshold: TimeInterval

    public init(
        countdownLateTolerance: TimeInterval = 2,
        promptDeadlineTolerance: TimeInterval = 2,
        backwardJumpTolerance: TimeInterval = 2,
        monotonicDriftTolerance: TimeInterval = 5,
        forwardGapThreshold: TimeInterval? = 12 * 3600,
        staleSessionThreshold: TimeInterval = 6 * 3600
    ) {
        self.countdownLateTolerance = countdownLateTolerance
        self.promptDeadlineTolerance = promptDeadlineTolerance
        self.backwardJumpTolerance = backwardJumpTolerance
        self.monotonicDriftTolerance = monotonicDriftTolerance
        self.forwardGapThreshold = forwardGapThreshold
        self.staleSessionThreshold = staleSessionThreshold
    }

    public static let standard = ReconcilePolicy()
}

public enum ClockAnomaly: Equatable, Sendable {
    /// Wall clock moved backwards by `seconds` relative to `previousNow` or the last transition.
    case backward(seconds: TimeInterval)
    /// Wall-clock elapsed disagrees with monotonic elapsed.
    case monotonicMismatch(wallSeconds: TimeInterval, monotonicSeconds: TimeInterval)
    /// Forward gap beyond `forwardGapThreshold` with no monotonic evidence.
    case forwardGapExceeded(seconds: TimeInterval)
}

/// Things the UI/coordinator must surface; they never change domain state by themselves.
public enum ReconcileSignal: Equatable, Sendable {
    /// Timing transitions were withheld; recorded durations untouched. Prompt the user, then call
    /// `reconcile(..., acknowledgeClockJump: true)` (or let them act via explicit commands).
    case clockJumpDetected(ClockAnomaly)
    /// Session idle beyond `staleSessionThreshold`: prompt resume / finish / abandon; never treat as
    /// silently ongoing.
    case recoveryPromptRequired(idleSeconds: TimeInterval)

    public var code: String {
        switch self {
        case .clockJumpDetected: "clock_jump_detected"
        case .recoveryPromptRequired: "recovery_prompt_required"
        }
    }
}

public struct ReconcileResult: Equatable, Sendable {
    /// Resulting state (== input when nothing changed).
    public var state: SessionState
    public var events: [DomainEvent]
    public var signals: [ReconcileSignal]
    /// Persist only when true. Each derived phase step bumped the revision by one.
    public var changed: Bool

    public var requiresUserReconciliation: Bool {
        signals.contains { if case .clockJumpDetected = $0 { true } else { false } }
    }
}

extension WorkoutReducer {
    /// Derives time-based events when the app is executing (foreground resume, in-process tick, intent):
    ///
    /// - `preCountdown`, deadline reached within `countdownLateTolerance` → `exercising` starting at the
    ///   countdown deadline (`countdownElapsed while foreground`). Reached later (app was suspended) or
    ///   implausibly far in the future (clock changed) → back to `ready` + `countdownLapsed`: never auto-start
    ///   a set without the app executing (UX §5).
    /// - timed `exercising`, deadline reached → `awaitingResult` (`targetDeadlineReached`). A draft is created
    ///   but **no set result**; the suggested actual is only pre-filled when reconciled promptly (ADR-009).
    /// - `resting`, deadline reached → `ready` (`restExpired`). Never starts exercising.
    /// - `paused`, `ready`, `awaitingResult`, `reviewingSummary`: no time-based transition.
    ///
    /// Clock anomalies (backward jump, monotonic mismatch, oversized forward gap) withhold all timing
    /// transitions and return `.clockJumpDetected` so the user reconciles; confirmed metrics are never touched.
    ///
    /// - Parameters:
    ///   - previousNow: last wall-clock reading the coordinator observed while executing (nil if none).
    ///   - monotonicElapsed: monotonic seconds elapsed since `previousNow`, only when the process ran
    ///     continuously in between (pass nil across suspension/kill).
    ///   - acknowledgeClockJump: the user confirmed the current time is correct; skip anomaly detection.
    public static func reconcile(
        _ state: SessionState,
        now: Date,
        previousNow: Date?,
        monotonicElapsed: TimeInterval? = nil,
        acknowledgeClockJump: Bool = false,
        policy: ReconcilePolicy = .standard
    ) -> ReconcileResult {
        guard state.status == .active else {
            return ReconcileResult(state: state, events: [], signals: [], changed: false)
        }

        var signals: [ReconcileSignal] = []
        if !acknowledgeClockJump,
           let anomaly = detectClockAnomaly(state: state, now: now, previousNow: previousNow, monotonicElapsed: monotonicElapsed, policy: policy) {
            return ReconcileResult(state: state, events: [], signals: [.clockJumpDetected(anomaly)], changed: false)
        }

        let idle = now.timeIntervalSince(state.updatedAt)
        if idle >= policy.staleSessionThreshold {
            signals.append(.recoveryPromptRequired(idleSeconds: idle))
        }

        var current = state
        var events: [DomainEvent] = []
        // Each step is one accepted transition. Bounded: at most countdown → exercising → awaiting.
        for _ in 0..<3 {
            guard let step = reconcileStep(current, now: now, policy: policy) else { break }
            current = step.state
            events.append(contentsOf: step.events)
        }
        return ReconcileResult(state: current, events: events, signals: signals, changed: current != state)
    }

    static func detectClockAnomaly(state: SessionState, now: Date, previousNow: Date?, monotonicElapsed: TimeInterval?, policy: ReconcilePolicy) -> ClockAnomaly? {
        if let previousNow, now.timeIntervalSince(previousNow) < -policy.backwardJumpTolerance {
            return .backward(seconds: previousNow.timeIntervalSince(now))
        }
        if now.timeIntervalSince(state.updatedAt) < -policy.backwardJumpTolerance {
            return .backward(seconds: state.updatedAt.timeIntervalSince(now))
        }
        guard let previousNow else { return nil }
        let wall = now.timeIntervalSince(previousNow)
        if let monotonicElapsed {
            if abs(wall - monotonicElapsed) > policy.monotonicDriftTolerance {
                return .monotonicMismatch(wallSeconds: wall, monotonicSeconds: monotonicElapsed)
            }
            return nil
        }
        if let threshold = policy.forwardGapThreshold, wall > threshold {
            return .forwardGapExceeded(seconds: wall)
        }
        return nil
    }

    static func reconcileStep(_ s: SessionState, now: Date, policy: ReconcilePolicy) -> Transition? {
        switch s.phase {
        case .preCountdown:
            guard let deadline = s.phaseDeadlineAt else { return nil }
            let lateMs = TimeMath.ms(from: deadline, to: now)
            let maxCountdownMs = TimeMath.ms(seconds: s.countdownSeconds ?? DomainLimits.countdownSeconds.upperBound)
            let toleranceMs = Int64(policy.countdownLateTolerance * 1000)
            var b = Builder(s)
            if lateMs >= 0 && lateMs <= toleranceMs {
                b.beginExercising(at: deadline) // countdownElapsed while foreground
            } else if lateMs > toleranceMs || -lateMs > maxCountdownMs + toleranceMs {
                b.events.append(.countdownLapsed(lateMs: lateMs))
                b.enterReady(now: now)
            } else {
                return nil
            }
            return b.commit(now: now)

        case .exercising:
            guard let deadline = s.phaseDeadlineAt, now >= deadline, let key = s.currentSetKey else { return nil }
            let lateMs = TimeMath.ms(from: deadline, to: now)
            let measured = max(0, s.accumulatedExerciseMs + (s.phaseStartedAt.map { TimeMath.ms(from: $0, to: deadline) } ?? 0))
            let prompt = lateMs <= Int64(policy.promptDeadlineTolerance * 1000)
            var b = Builder(s)
            b.enterAwaitingResult(
                ResultDraft(key: key, measuredElapsedMs: measured, suggestedActualMs: prompt ? measured : nil, endReason: .targetDeadlineReached(lateMs: lateMs)),
                now: now
            )
            return b.commit(now: now)

        case .resting:
            guard let deadline = s.phaseDeadlineAt, now >= deadline else { return nil }
            var b = Builder(s)
            b.enterReady(now: now) // restExpired → ready; never exercising
            return b.commit(now: now)

        case .ready, .paused, .awaitingResult, .reviewingSummary, .completed, .abandoned:
            return nil
        }
    }
}
