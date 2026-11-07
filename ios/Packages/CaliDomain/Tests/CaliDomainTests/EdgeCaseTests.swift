import CaliDomain
import XCTest

/// docs/03 §7 edge cases #1, #3, #4, #5, #7 (others belong to CaliCore / widget / sync layers).
final class EdgeCaseTests: XCTestCase {

    /// #1 Double tap / widget-and-app race: second confirm for the same set is a duplicate,
    /// carrying the canonical result id so the coordinator can return it idempotently.
    func testEdge1DoubleTapConfirm() {
        let h = Harness()
        h.toAwaitingResult()
        let key = h.s.currentSetKey!
        let tap = h.confirm(setResultId: uuid(4242))
        h.send(tap)
        // Exact replay of the same command (same commandId): the reducer still never double counts;
        // commandId dedupe that returns the stored transition is CaliCore's job (docs/03 §6).
        guard case .failure(.duplicateSetResolution(let existing)) = WorkoutReducer.reduce(h.s, tap, now: h.now) else {
            return XCTFail("expected duplicate")
        }
        XCTAssertEqual(existing.setResultId, uuid(4242))
        XCTAssertEqual(existing.key, key)
        XCTAssertEqual(h.s.resolvedSets.count, 1)
    }

    /// #3 Hold deadline passes while locked: on unlock → awaitingResult, ask for actual, no auto-complete.
    func testEdge3HoldDeadlineWhileLocked() {
        let h = Harness()
        h.toExercising() // started t0+3, deadline t0+15
        let lockedAt = h.now
        h.clock.sleep(for: 60)
        let r = h.reconcile(previousNow: lockedAt)
        XCTAssertEqual(h.s.phase, .awaitingResult)
        XCTAssertEqual(h.s.pendingResult?.endReason, .targetDeadlineReached(lateMs: 48_000))
        XCTAssertNil(h.s.pendingResult?.suggestedActualMs)
        XCTAssertEqual(r.events.codes, ["phase_changed", "deadline_changed"])
        // The user says they actually held 20s (kept going past the target while locked).
        let t = h.send(h.confirm(holdMs: 20_000))
        XCTAssertEqual(t.setRecords.first?.actual.holdMs, 20_000)
        XCTAssertEqual(t.setRecords.first?.endReason, .targetDeadlineReached(lateMs: 48_000))
    }

    /// #4 Clock changed during rest: detect, withhold, require user reconciliation; confirmed metrics untouched.
    func testEdge4ClockJumpBackwardDuringRest() {
        let h = Harness()
        h.toResting()
        let confirmed = h.s.resolvedSets
        let restDeadline = h.s.phaseDeadlineAt
        let observed = h.now
        h.clock.jumpWallClock(by: -3_600)
        let r = h.reconcile(previousNow: observed, monotonicElapsed: 0)
        XCTAssertEqual(r.signals, [.clockJumpDetected(.backward(seconds: 3_600))])
        XCTAssertTrue(r.requiresUserReconciliation)
        XCTAssertFalse(r.changed)
        XCTAssertEqual(h.s.phaseDeadlineAt, restDeadline)
        XCTAssertEqual(h.s.resolvedSets, confirmed)
    }

    func testEdge4ClockJumpForwardDetectedByMonotonicMismatch() {
        let h = Harness()
        h.toResting()
        let observed = h.now
        h.clock.advance(by: 5)
        h.clock.jumpWallClock(by: 7_200)
        let r = h.reconcile(previousNow: observed, monotonicElapsed: 5)
        XCTAssertEqual(r.signals, [.clockJumpDetected(.monotonicMismatch(wallSeconds: 7_205, monotonicSeconds: 5))])
        XCTAssertEqual(h.s.phase, .resting, "rest is not silently expired by a wall-clock jump")
        // After the user acknowledges the new time, the rest expires to READY — never EXERCISING.
        h.reconcile(previousNow: observed, monotonicElapsed: 5, acknowledge: true)
        XCTAssertEqual(h.s.phase, .ready)
    }

    func testEdge4ForwardGapWithoutMonotonicEvidence() {
        let h = Harness()
        h.toResting()
        let observed = h.now
        h.clock.sleep(for: 13 * 3_600)
        let r = h.reconcile(previousNow: observed)
        XCTAssertEqual(r.signals, [.clockJumpDetected(.forwardGapExceeded(seconds: 46_800.0))])
        XCTAssertFalse(r.changed)
    }

    func testEdge4BackwardJumpBeforeLastTransitionWithoutPreviousNow() {
        let h = Harness()
        h.toResting()
        h.clock.jumpWallClock(by: -600)
        let r = h.reconcile(previousNow: nil)
        XCTAssertEqual(r.signals, [.clockJumpDetected(.backward(seconds: 600))])
    }

    func testEdge4SmallDriftWithinToleranceIsNotAJump() {
        let h = Harness()
        h.toResting()
        let observed = h.now
        h.clock.advance(by: 10)
        h.clock.jumpWallClock(by: -1.5)
        let r = h.reconcile(previousNow: observed, monotonicElapsed: 10)
        XCTAssertEqual(r.signals, [])
    }

    func testEdge4AbandonAfterBackwardJumpClampsFinishedAtToStart() {
        let h = Harness()
        h.send(h.create([Specs.reps()]))
        h.clock.jumpWallClock(by: -600)
        h.send(h.abandon("clock"))
        XCTAssertEqual(h.s.status, .abandoned)
        XCTAssertEqual(h.s.abandonedAt, h.now)
        XCTAssertEqual(h.s.finishedAt, h.s.startedAt, "finishedAt never precedes startedAt")
    }

    func testEdge4StopSetAfterBackwardJumpDoesNotInventDuration() {
        let h = Harness()
        h.send(h.create([Specs.reps()]))
        h.send(h.startSet(countdown: 0))
        h.clock.jumpWallClock(by: -30)
        h.send(h.stopSet())
        XCTAssertEqual(h.s.pendingResult?.measuredElapsedMs, 0)
        XCTAssertNil(h.s.pendingResult?.suggestedActualMs)
    }

    /// #5 Rest finishes while locked: on unlock → READY, never EXERCISING; no set result created.
    func testEdge5RestFinishesWhileLocked() {
        let h = Harness()
        h.toResting()
        let records = h.s.resolvedSets
        let lockedAt = h.now
        h.clock.sleep(for: 600)
        let r = h.reconcile(previousNow: lockedAt)
        XCTAssertEqual(h.s.phase, .ready)
        XCTAssertEqual(h.s.currentSetIndex, 2)
        XCTAssertEqual(h.s.resolvedSets, records)
        XCTAssertEqual(r.events.codes, ["phase_changed", "deadline_changed"])
        // User must explicitly start the next set.
        h.send(h.startSet())
        XCTAssertEqual(h.s.phase, .preCountdown)
    }

    /// Countdown elapsed while the app was suspended (lock during 3-2-1): back to READY, set not started.
    func testCountdownLapsedWhileSuspendedReturnsToReady() {
        let h = Harness()
        h.toPreCountdown()
        h.clock.sleep(for: 30)
        let r = h.reconcile(previousNow: t0)
        XCTAssertEqual(h.s.phase, .ready)
        XCTAssertEqual(r.events.first, .countdownLapsed(lateMs: 27_000))
        XCTAssertEqual(h.s.resolvedSets, [])
    }

    func testCountdownWithImplausibleFutureDeadlineReturnsToReadyAfterAcknowledge() {
        let h = Harness()
        h.toPreCountdown()
        h.clock.jumpWallClock(by: -600)
        XCTAssertTrue(h.reconcile(previousNow: t0, monotonicElapsed: 0).requiresUserReconciliation)
        let r = h.reconcile(previousNow: t0, monotonicElapsed: 0, acknowledge: true)
        XCTAssertEqual(h.s.phase, .ready)
        XCTAssertEqual(r.events.first?.code, "countdown_lapsed")
    }

    /// #7 App force-quit, reopened hours later: prompt resume/finish/abandon; never silently ongoing.
    func testEdge7StaleSessionInExercising() {
        let h = Harness()
        h.toExercising()
        h.clock.sleep(for: 7 * 3_600)
        let r = h.reconcile(previousNow: nil)
        XCTAssertEqual(h.s.phase, .awaitingResult)
        XCTAssertNil(h.s.pendingResult?.suggestedActualMs)
        XCTAssertEqual(h.s.resolvedSets, [])
        XCTAssertEqual(r.signals.map(\.code), ["recovery_prompt_required"])
        XCTAssertEqual(h.s.status, .active)
    }

    func testEdge7StaleSessionInReadyOnlySignals() {
        let h = Harness()
        h.toReady()
        h.clock.sleep(for: 6 * 3_600)
        let r = h.reconcile(previousNow: nil)
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.signals, [.recoveryPromptRequired(idleSeconds: 21_600.0)])
        // The user may abandon or finish explicitly; neither happens automatically.
        h.send(h.abandon("forgot to finish"))
        XCTAssertEqual(h.s.status, .abandoned)
    }

    func testReconcileOnTerminalSessionIsNoOp() {
        let h = Harness()
        h.toCompleted()
        h.clock.sleep(for: 100_000)
        let r = h.reconcile(previousNow: nil)
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.signals, [])
    }
}
