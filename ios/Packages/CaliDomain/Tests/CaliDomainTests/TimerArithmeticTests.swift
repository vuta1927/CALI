import CaliDomain
import XCTest

/// Pause/resume deadline arithmetic and repeated rest extensions (docs/03 §5, UX §5).
final class TimerArithmeticTests: XCTestCase {

    func testMultiplePauseResumeCyclesAccumulateExerciseTime() {
        let h = Harness()
        h.toExercising() // hold 12s; started t0+3, deadline t0+15
        h.clock.advance(by: 4)
        h.send(h.pause())
        XCTAssertEqual(h.s.accumulatedExerciseMs, 4_000)
        XCTAssertEqual(h.s.pausedRemainingMs, 8_000)

        h.clock.advance(by: 100)
        h.send(h.resume())
        XCTAssertEqual(h.s.phaseDeadlineAt, h.now.addingTimeInterval(8))
        XCTAssertEqual(h.s.exerciseElapsedMs(at: h.now), 4_000)

        h.clock.advance(by: 3)
        XCTAssertEqual(h.s.exerciseElapsedMs(at: h.now), 7_000)
        XCTAssertEqual(h.s.remainingMs(at: h.now), 5_000)
        h.send(h.pause())
        XCTAssertEqual(h.s.accumulatedExerciseMs, 7_000)
        XCTAssertEqual(h.s.pausedRemainingMs, 5_000)

        h.clock.advance(by: 20)
        h.send(h.resume())
        h.clock.advance(by: 5)
        let resumedAt = h.now.addingTimeInterval(-5)
        h.reconcile(previousNow: resumedAt, monotonicElapsed: 5)
        XCTAssertEqual(h.s.phase, .awaitingResult)
        XCTAssertEqual(h.s.pendingResult?.measuredElapsedMs, 12_000, "pause time excluded")
        XCTAssertEqual(h.s.pendingResult?.suggestedActualMs, 12_000)
    }

    func testStopAfterResumeMeasuresOnlyExercisingTime() {
        let h = Harness()
        h.toExercising()
        h.clock.advance(by: 2.5)
        h.send(h.pause())
        h.clock.advance(by: 60)
        h.send(h.resume())
        h.clock.advance(by: 1.25)
        h.send(h.stopSet())
        XCTAssertEqual(h.s.pendingResult?.measuredElapsedMs, 3_750)
    }

    func testPauseAtExactDeadlineFreezesZeroRemaining() {
        let h = Harness()
        h.toExercising()
        h.clock.advance(by: 12)
        h.send(h.pause()) // user pressed pause before the tick reconciled the deadline
        XCTAssertEqual(h.s.pausedRemainingMs, 0)
        h.send(h.resume())
        XCTAssertEqual(h.s.phaseDeadlineAt, h.now)
        h.reconcile()
        XCTAssertEqual(h.s.phase, .awaitingResult)
    }

    func testPauseAfterBackwardClockJumpNeverInflatesRemaining() {
        let h = Harness()
        h.toExercising()
        h.clock.jumpWallClock(by: -300)
        h.send(h.pause())
        XCTAssertEqual(h.s.pausedRemainingMs, 12_000, "remaining clamps to the target")
        XCTAssertEqual(h.s.accumulatedExerciseMs, 0, "negative segment clamps to zero")
    }

    func testUntimedSetHasNoDeadlineThroughPauseAndResume() {
        let h = Harness()
        h.send(h.create([Specs.reps()]))
        h.send(h.startSet(countdown: 0))
        XCTAssertNil(h.s.phaseDeadlineAt)
        h.clock.advance(by: 10)
        h.send(h.pause())
        XCTAssertNil(h.s.pausedRemainingMs)
        h.send(h.resume())
        XCTAssertNil(h.s.phaseDeadlineAt)
        h.clock.sleep(for: 3_600)
        h.reconcile()
        XCTAssertEqual(h.s.phase, .exercising, "reps sets only end by explicit StopSet")
    }

    func testRepeatedPlus30RestExtensions() {
        let h = Harness()
        h.toResting()
        let original = h.s.phaseDeadlineAt!
        for i in 1...5 {
            h.clock.advance(by: 1)
            h.send(h.extendRest(30))
            XCTAssertEqual(h.s.phaseDeadlineAt, original.addingTimeInterval(Double(30 * i)))
        }
        XCTAssertEqual(h.s.phase, .resting)
    }

    func testExtendOverdueRestCountsFromNow() {
        let h = Harness()
        h.toResting()
        h.clock.sleep(for: 200) // rest (90s) overdue, not reconciled yet
        h.send(h.extendRest(30))
        XCTAssertEqual(h.s.phaseDeadlineAt, h.now.addingTimeInterval(30))
        XCTAssertEqual(h.s.phase, .resting)
    }

    func testRestExtensionCappedAtMaxRemaining() {
        let h = Harness()
        h.send(h.create([Specs.hold(rest: 3_500)]))
        h.send(h.startSet(countdown: 0))
        h.clock.advance(by: 5)
        h.send(h.stopSet())
        h.send(h.confirm())
        h.send(h.extendRest(100)) // 3600 remaining: allowed
        XCTAssertEqual(h.s.remainingMs(at: h.now), 3_600_000)
        XCTAssertEqual(h.reject(h.extendRest(1))?.code, "validation_failed")
    }

    func testExtendRestIncrementBounds() {
        let h = Harness()
        h.toResting()
        XCTAssertEqual(h.reject(h.extendRest(0))?.code, "validation_failed")
        XCTAssertEqual(h.reject(h.extendRest(-30))?.code, "validation_failed")
        XCTAssertEqual(h.reject(h.extendRest(3_601))?.code, "validation_failed")
    }

    func testZeroRestBetweenSetsExpiresOnNextReconcile() {
        let h = Harness()
        h.send(h.create([Specs.hold(rest: 0)]))
        h.send(h.startSet(countdown: 0))
        h.clock.advance(by: 5)
        h.send(h.stopSet())
        h.send(h.confirm())
        XCTAssertEqual(h.s.phase, .resting)
        XCTAssertEqual(h.s.phaseDeadlineAt, h.now)
        h.reconcile()
        XCTAssertEqual(h.s.phase, .ready)
    }
}
