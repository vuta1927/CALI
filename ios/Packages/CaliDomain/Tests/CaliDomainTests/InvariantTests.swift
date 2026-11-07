import CaliDomain
import XCTest

/// Hard invariants (docs/03 §4 invariants, ADR-009, task I1a).
final class InvariantTests: XCTestCase {

    /// ADR-009: no deadline — however late, however reconciled — ever produces a set result.
    func testDeadlineNeverInfersCompletedSet() {
        for lateness: TimeInterval in [0, 1, 2, 3, 60, 3_600, 18_000] {
            let h = Harness()
            h.toExercising()
            let exercisingSince = h.now
            h.clock.sleep(for: 12 + lateness)
            let r = h.reconcile(previousNow: exercisingSince)
            XCTAssertEqual(h.s.phase, .awaitingResult, "lateness \(lateness)")
            XCTAssertEqual(h.s.resolvedSets, [])
            XCTAssertEqual(h.s.confirmedSetCount, 0)
            XCTAssertFalse(r.events.contains { ["set_confirmed", "set_skipped"].contains($0.code) })
            // Reconcile again, much later: still waiting for the user.
            h.clock.sleep(for: 600)
            h.reconcile()
            XCTAssertEqual(h.s.phase, .awaitingResult)
            XCTAssertEqual(h.s.resolvedSets, [])
        }
    }

    func testLateDeadlineDoesNotPrefillSuggestedActual() {
        let h = Harness()
        h.toExercising()
        h.clock.sleep(for: 12 + 3)
        h.reconcile()
        XCTAssertNil(h.s.pendingResult?.suggestedActualMs, "late reconcile must ask for actual, not suggest the target")
        XCTAssertEqual(h.s.pendingResult?.measuredElapsedMs, 12_000, "measured clamps at the deadline")
        XCTAssertEqual(h.s.pendingResult?.endReason, .targetDeadlineReached(lateMs: 3_000))
    }

    func testDuplicateConfirmIsRejectedAndNeverDoubleCounts() {
        let h = Harness()
        h.toAwaitingResult()
        let key = h.s.currentSetKey!
        let first = h.send(h.confirm(setResultId: uuid(777)))
        let resolved = first.setRecords[0]
        let afterFirst = h.s
        let err = h.reject(h.confirm(key: key, setResultId: uuid(778)))
        XCTAssertEqual(err, .duplicateSetResolution(existing: ResolvedSet(key: key, setResultId: uuid(777), status: .completed)))
        XCTAssertEqual(h.s, afterFirst)
        XCTAssertEqual(h.s.confirmedSetCount, 1)
        XCTAssertEqual(resolved.setResultId, uuid(777))
        // A skip for the same set is a duplicate resolution too.
        XCTAssertEqual(h.reject(h.skip(key: key))?.code, "duplicate_set_resolution")
    }

    func testRestingNeverAutoStartsExercising() {
        let h = Harness()
        h.toResting()
        for _ in 0..<5 {
            h.clock.sleep(for: 3_000)
            h.reconcile()
            XCTAssertNotEqual(h.s.phase, .exercising)
            XCTAssertNotEqual(h.s.phase, .preCountdown)
        }
        XCTAssertEqual(h.s.phase, .ready)
    }

    func testPausedHasNoMovingDeadlineAndResumeRecomputes() {
        let h = Harness()
        h.toExercising() // deadline t0+15
        h.clock.advance(by: 4)
        h.send(h.pause())
        XCTAssertNil(h.s.phaseDeadlineAt)
        XCTAssertEqual(h.s.pausedRemainingMs, 8_000)
        h.clock.sleep(for: 10_000)
        let r = h.reconcile()
        XCTAssertEqual(h.s.phase, .paused, "time never ends a paused set")
        XCTAssertEqual(h.s.remainingMs(at: h.now), 8_000)
        XCTAssertTrue(r.events.isEmpty)
        h.send(h.resume())
        XCTAssertEqual(h.s.phaseDeadlineAt, h.now.addingTimeInterval(8))
    }

    func testRevisionIncrementsOnEveryAcceptedTransitionOnly() {
        let h = Harness()
        h.toReady()
        var expected = 1
        func step(_ c: Command) { h.send(c); expected += 1; XCTAssertEqual(h.s.revision, expected) }
        step(h.startSet(countdown: 0))
        h.clock.advance(by: 2)
        step(h.pause())
        XCTAssertNotNil(h.reject(h.pause()))
        XCTAssertEqual(h.s.revision, expected, "rejections do not bump revision")
        step(h.resume())
        h.clock.advance(by: 2)
        step(h.stopSet())
        step(h.confirm())
        step(h.extendRest())
        step(h.extendRest())
        step(h.readyNext())
        step(h.abandon())
    }

    func testRejectedCommandIsPure() {
        let h = Harness()
        h.toResting()
        let before = h.s
        _ = WorkoutReducer.reduce(before, h.pause(), now: h.now.addingTimeInterval(5))
        XCTAssertEqual(h.s, before)
    }

    func testReducerIsDeterministic() {
        let h = Harness()
        h.toAwaitingResult()
        let c = h.confirm()
        let a = WorkoutReducer.reduce(h.s, c, now: h.now)
        let b = WorkoutReducer.reduce(h.s, c, now: h.now)
        XCTAssertEqual(a, b)
    }
}
