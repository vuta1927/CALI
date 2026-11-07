import CaliDomain
import XCTest

/// docs/03 §4 transition table: every legal transition, plus the full illegal matrix per state.
final class TransitionTests: XCTestCase {

    // MARK: Legal transitions

    func testCreateSessionStartsInReadyAtRevisionOne() {
        let h = Harness()
        let t = h.send(h.create())
        XCTAssertEqual(h.s.phase, .ready)
        XCTAssertEqual(h.s.status, .active)
        XCTAssertEqual(h.s.revision, 1)
        XCTAssertEqual(h.s.currentExecutionIndex, 0)
        XCTAssertEqual(h.s.currentSetIndex, 1)
        XCTAssertEqual(h.s.startedAt, t0)
        XCTAssertEqual(t.events.codes, ["session_created"])
    }

    func testNonCreateCommandWithoutSessionIsRejected() {
        let h = Harness()
        XCTAssertEqual(h.reject(h.pause()), .noSession)
    }

    func testStartSetEntersPreCountdownWithDeadline() {
        let h = Harness()
        h.toReady()
        let t = h.send(h.startSet(countdown: 3))
        XCTAssertEqual(h.s.phase, .preCountdown)
        XCTAssertEqual(h.s.phaseDeadlineAt, t0.addingTimeInterval(3))
        XCTAssertEqual(t.events.codes, ["phase_changed", "deadline_changed"])
    }

    func testStartSetWithCountdownDisabledEntersExercisingDirectly() {
        let h = Harness()
        h.toReady()
        h.send(h.startSet(countdown: 0))
        XCTAssertEqual(h.s.phase, .exercising)
        XCTAssertEqual(h.s.phaseDeadlineAt, t0.addingTimeInterval(12))
    }

    func testCountdownElapsedWhileForegroundStartsExercisingAtCountdownDeadline() {
        let h = Harness()
        h.toPreCountdown()
        h.clock.advance(by: 3.5)
        let r = h.reconcile(previousNow: t0, monotonicElapsed: 3.5)
        XCTAssertEqual(h.s.phase, .exercising)
        XCTAssertEqual(h.s.phaseStartedAt, t0.addingTimeInterval(3), "set starts at countdown end, not reconcile time")
        XCTAssertEqual(h.s.phaseDeadlineAt, t0.addingTimeInterval(15))
        XCTAssertEqual(r.events.codes, ["phase_changed", "deadline_changed"])
    }

    func testCountdownNotYetElapsedIsNoOp() {
        let h = Harness()
        h.toPreCountdown()
        h.clock.advance(by: 1)
        let r = h.reconcile(previousNow: t0, monotonicElapsed: 1)
        XCTAssertFalse(r.changed)
        XCTAssertEqual(h.s.phase, .preCountdown)
    }

    func testPauseFromExercising() {
        let h = Harness()
        h.toExercising()
        h.clock.advance(by: 4)
        h.send(h.pause())
        XCTAssertEqual(h.s.phase, .paused)
        XCTAssertNil(h.s.phaseDeadlineAt)
    }

    func testResumeFromPaused() {
        let h = Harness()
        h.toPaused()
        h.send(h.resume())
        XCTAssertEqual(h.s.phase, .exercising)
        XCTAssertNotNil(h.s.phaseDeadlineAt)
    }

    func testStopSetEntersAwaitingResultWithDraftAndNoSetResult() {
        let h = Harness()
        h.toExercising()
        h.clock.advance(by: 5)
        let t = h.send(h.stopSet())
        XCTAssertEqual(h.s.phase, .awaitingResult)
        XCTAssertEqual(h.s.pendingResult?.measuredElapsedMs, 5_000)
        XCTAssertEqual(h.s.pendingResult?.suggestedActualMs, 5_000)
        XCTAssertEqual(h.s.pendingResult?.endReason, .userStopped)
        XCTAssertEqual(t.setRecords, [])
        XCTAssertEqual(h.s.resolvedSets, [])
    }

    func testTimedDeadlineReconciledEntersAwaitingResult() {
        let h = Harness()
        h.toExercising()
        h.clock.advance(by: 12)
        let r = h.reconcile(previousNow: h.now.addingTimeInterval(-12), monotonicElapsed: 12)
        XCTAssertEqual(h.s.phase, .awaitingResult)
        XCTAssertEqual(h.s.pendingResult?.endReason, .targetDeadlineReached(lateMs: 0))
        XCTAssertEqual(h.s.pendingResult?.suggestedActualMs, 12_000)
        XCTAssertFalse(r.events.contains { $0.code == "set_confirmed" })
    }

    func testConfirmSetWithMoreSetsEntersRestingWithDeadline() {
        let h = Harness()
        h.toAwaitingResult()
        let key = h.s.currentSetKey!
        let t = h.send(h.confirm())
        XCTAssertEqual(h.s.phase, .resting)
        XCTAssertEqual(h.s.currentSetIndex, 2)
        XCTAssertEqual(h.s.phaseDeadlineAt, h.now.addingTimeInterval(90))
        XCTAssertEqual(t.setRecords.count, 1)
        XCTAssertEqual(t.setRecords.first?.key, key)
        XCTAssertEqual(t.setRecords.first?.status, .completed)
        XCTAssertEqual(t.setRecords.first?.actual.holdMs, 12_000)
        XCTAssertEqual(t.setRecords.first?.prescribed.target, .staticHold(holdSeconds: 12))
        XCTAssertEqual(t.events.codes, ["set_confirmed", "phase_changed", "deadline_changed"])
    }

    func testConfirmLastSetOfExerciseMovesToNextExerciseReady() {
        let h = Harness()
        h.send(h.create([Specs.hold(sets: 1), Specs.reps()]))
        h.send(h.startSet(countdown: 0))
        h.clock.advance(by: 5)
        h.send(h.stopSet())
        h.send(h.confirm())
        XCTAssertEqual(h.s.phase, .ready)
        XCTAssertEqual(h.s.currentExecutionIndex, 1)
        XCTAssertEqual(h.s.currentSetIndex, 1)
    }

    func testExtendRestInResting() {
        let h = Harness()
        h.toResting()
        let before = h.s.phaseDeadlineAt!
        h.send(h.extendRest(30))
        XCTAssertEqual(h.s.phase, .resting)
        XCTAssertEqual(h.s.phaseDeadlineAt, before.addingTimeInterval(30))
    }

    func testReadyNextFromResting() {
        let h = Harness()
        h.toResting()
        h.send(h.readyNext())
        XCTAssertEqual(h.s.phase, .ready)
        XCTAssertNil(h.s.phaseDeadlineAt)
    }

    func testRestExpiredReconciledEntersReady() {
        let h = Harness()
        h.toResting()
        h.clock.advance(by: 90)
        h.reconcile(previousNow: h.now.addingTimeInterval(-90), monotonicElapsed: 90)
        XCTAssertEqual(h.s.phase, .ready)
    }

    func testSkipSetFromReadyExercisingAndAwaitingResult() {
        for phase in [Phase.ready, .exercising, .awaitingResult] {
            let h = Harness()
            h.reach(phase)
            let key = h.s.currentSetKey!
            let t = h.send(h.skip())
            XCTAssertEqual(t.setRecords.first?.status, .skipped, "\(phase)")
            XCTAssertEqual(t.setRecords.first?.key, key)
            XCTAssertEqual(t.setRecords.first?.skipReason, "wrist pain")
            XCTAssertEqual(h.s.phase, .ready, "skip does not earn rest (\(phase))")
            XCTAssertEqual(h.s.currentSetIndex, 2)
            XCTAssertEqual(h.s.skippedSetCount, 1)
            XCTAssertEqual(h.s.confirmedSetCount, 0)
        }
    }

    func testFinalSetGoesToReviewingSummaryAndStaysActive() {
        let h = Harness()
        h.send(h.create([Specs.hold(sets: 1)]))
        h.send(h.startSet(countdown: 0))
        h.clock.advance(by: 12)
        h.reconcile(previousNow: t0, monotonicElapsed: 12)
        h.send(h.confirm())
        XCTAssertEqual(h.s.phase, .reviewingSummary)
        XCTAssertEqual(h.s.status, .active, "final set must not complete the session")
        XCTAssertNil(h.s.finishedAt)
    }

    func testOnlyFinishSessionCompletes() {
        let h = Harness()
        h.toReviewingSummary()
        // Time passing does not complete a session.
        h.clock.advance(by: 3_600)
        h.reconcile()
        XCTAssertEqual(h.s.status, .active)
        let t = h.send(h.finish())
        XCTAssertEqual(h.s.status, .completed)
        XCTAssertEqual(h.s.phase, .completed)
        XCTAssertEqual(h.s.finishedAt, h.now)
        XCTAssertEqual(t.events.codes, ["session_finished", "phase_changed"])
    }

    func testAbandonAllowedFromEveryActivePhase() {
        for phase in Phase.allCases where !phase.isTerminal {
            let h = Harness()
            h.reach(phase)
            let t = h.send(h.abandon("knee"))
            XCTAssertEqual(h.s.status, .abandoned, "\(phase)")
            XCTAssertEqual(h.s.phase, .abandoned)
            XCTAssertEqual(h.s.abandonReason, "knee")
            XCTAssertEqual(h.s.abandonedAt, h.now)
            XCTAssertEqual(h.s.finishedAt, h.now, "ADR-017: finishedAt is set for abandoned sessions too")
            XCTAssertNil(h.s.pendingResult, "a pending draft is discarded, never turned into a result")
            XCTAssertEqual(t.setRecords, [])
            XCTAssertEqual(t.events.first?.code, "session_abandoned")
        }
    }

    func testNewSessionAllowedAfterTerminalSession() {
        for phase in [Phase.completed, .abandoned] {
            let h = Harness()
            h.reach(phase)
            h.send(h.create(sessionId: uuid(5001)))
            XCTAssertEqual(h.s.sessionId, uuid(5001))
            XCTAssertEqual(h.s.revision, 1)
        }
    }

    // MARK: Illegal matrix

    /// Commands accepted per phase. Everything else must be rejected with state untouched.
    static let allowed: [Phase: Set<CommandKind>] = [
        .ready: [.startSet, .skipSet, .abandonSession],
        .preCountdown: [.abandonSession],
        .exercising: [.pause, .stopSet, .skipSet, .abandonSession],
        .paused: [.resume, .abandonSession],
        .awaitingResult: [.confirmSet, .skipSet, .abandonSession],
        .resting: [.extendRest, .readyNext, .abandonSession],
        .reviewingSummary: [.finishSession, .abandonSession],
        .completed: [.createSession],
        .abandoned: [.createSession],
    ]

    func testTransitionMatrix() {
        for phase in Phase.allCases {
            for kind in CommandKind.allCases {
                let h = Harness()
                h.reach(phase)
                let before = h.s
                let isAllowed = Self.allowed[phase]!.contains(kind)
                let result = WorkoutReducer.reduce(before, h.command(kind), now: h.now)
                switch (result, isAllowed) {
                case (.success, true):
                    break
                case (.failure(let e), false):
                    if phase.isTerminal {
                        XCTAssertEqual(e, .sessionNotActive(before.status), "\(phase) \(kind)")
                    } else if kind == .createSession {
                        XCTAssertEqual(e, .activeSessionExists(sessionId: before.sessionId))
                    } else {
                        XCTAssertTrue(["invalid_transition", "duplicate_set_resolution"].contains(e.code), "\(phase) \(kind): \(e)")
                    }
                case (.success(let t), false):
                    XCTFail("\(kind) must be rejected in \(phase); got \(t.state.phase)")
                case (.failure(let e), true):
                    XCTFail("\(kind) must be accepted in \(phase); got \(e)")
                }
            }
        }
    }

    func testStopSetFromPausedIsRejected() {
        let h = Harness()
        h.toPaused()
        XCTAssertEqual(h.reject(h.stopSet()), .invalidTransition(from: .paused, command: .stopSet))
    }

    func testCommandForStaleSetIsRejected() {
        let h = Harness()
        h.toAwaitingResult()
        let wrong = SetKey(executionId: Specs.holdId, setIndex: 2)
        XCTAssertEqual(h.reject(h.confirm(key: wrong)), .setMismatch(expected: h.s.currentSetKey!, received: wrong))
        XCTAssertEqual(h.reject(h.skip(key: wrong)), .setMismatch(expected: h.s.currentSetKey!, received: wrong))
    }

    func testFinishBeforeStartTimestampIsRejected() {
        let h = Harness()
        h.toReviewingSummary()
        h.clock.set(now: t0.addingTimeInterval(-60))
        XCTAssertEqual(h.reject(h.finish()), .timestampBeforeSessionStart)
    }
}
