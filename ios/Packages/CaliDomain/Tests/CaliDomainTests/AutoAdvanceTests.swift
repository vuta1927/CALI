import CaliDomain
import Foundation
import XCTest

/// IOS-021: "Tự động chuyển set" — a rest found over while the app executes starts the next set; never a set result.
final class AutoAdvanceTests: XCTestCase {
    private let on = ReconcilePolicy(autoAdvance: true)

    private func tick(_ h: Harness, policy: ReconcilePolicy? = nil) -> ReconcileResult {
        h.reconcile(previousNow: h.now.addingTimeInterval(-1), monotonicElapsed: 1, policy: policy ?? on)
    }

    func testOnTimeRestStartsExercisingAtDeadline() {
        let h = Harness()
        h.toResting()
        let deadline = h.s.phaseDeadlineAt!
        let resolved = h.s.resolvedSets
        h.clock.advance(by: 91)
        let r = tick(h)
        XCTAssertEqual(r.state.phase, .exercising)
        XCTAssertEqual(r.state.currentSetIndex, 2)
        XCTAssertEqual(r.state.phaseStartedAt, deadline, "exercise starts at the rest deadline, not at reconcile time")
        XCTAssertEqual(r.state.phaseDeadlineAt, deadline.addingTimeInterval(12), "timed hold keeps its target deadline")
        XCTAssertEqual(r.state.resolvedSets, resolved, "auto-advance never resolves a set")
        XCTAssertTrue(Transition(state: r.state, events: r.events).setRecords.isEmpty, "no SetRecord produced")
        XCTAssertEqual(r.events.map(\.code), ["phase_changed", "deadline_changed"])
    }

    func testRepsSetEntersExercisingWithoutDeadlineAndWaitsForStop() {
        let h = Harness()
        h.send(h.create([Specs.reps(sets: 2, rest: 60)]))
        h.send(h.startSet(countdown: 0))
        h.clock.advance(by: 30)
        h.send(h.stopSet())
        h.send(h.confirm())
        XCTAssertEqual(h.s.phase, .resting)
        h.clock.advance(by: 60)
        _ = tick(h)
        XCTAssertEqual(h.s.phase, .exercising)
        XCTAssertNil(h.s.phaseDeadlineAt, "reps: no deadline, the user taps Xong set")
        h.clock.advance(by: 600)
        XCTAssertFalse(tick(h).changed, "nothing is inferred while a reps set runs")
        XCTAssertEqual(h.s.confirmedSetCount, 1)
        h.send(h.stopSet())
        XCTAssertEqual(h.s.phase, .awaitingResult)
    }

    func testLateRestGoesToReadyWithRestLapsed() {
        let h = Harness()
        h.toResting()
        h.clock.sleep(for: 300) // locked: the app was not executing
        let r = h.reconcile(previousNow: nil, policy: on)
        XCTAssertEqual(r.state.phase, .ready)
        XCTAssertEqual(r.events.first?.code, "rest_lapsed")
        if case .restLapsed(let late)? = r.events.first { XCTAssertEqual(late, 210_000) } else { XCTFail("restLapsed expected") }
        XCTAssertEqual(r.state.confirmedSetCount, 1)
        XCTAssertTrue(Transition(state: r.state, events: r.events).setRecords.isEmpty)
    }

    func testToleranceBoundary() {
        let h = Harness()
        h.toResting()
        h.clock.advance(by: 92) // exactly 2 s late
        XCTAssertEqual(tick(h).state.phase, .exercising)

        let late = Harness()
        late.toResting()
        late.clock.advance(by: 92.01)
        XCTAssertEqual(tick(late).state.phase, .ready)
    }

    func testDisabledKeepsRestToReady() {
        let h = Harness()
        h.toResting()
        h.clock.advance(by: 90)
        let r = tick(h, policy: .standard)
        XCTAssertEqual(r.state.phase, .ready)
        XCTAssertFalse(r.events.contains { $0.code == "rest_lapsed" })
    }

    func testClockAnomalyWithholdsAutoAdvance() {
        let h = Harness()
        h.toResting()
        let before = h.now
        h.clock.advance(by: 5)
        h.clock.jumpWallClock(by: 3_600)
        let r = h.reconcile(previousNow: before, monotonicElapsed: 5, policy: on)
        XCTAssertEqual(r.signals.map(\.code), ["clock_jump_detected"])
        XCTAssertFalse(r.changed)
        XCTAssertEqual(h.s.phase, .resting)
    }

    func testExtendedRestAutoAdvancesAtNewDeadline() {
        let h = Harness()
        h.toResting()
        h.send(h.extendRest(30))
        h.clock.advance(by: 90)
        XCTAssertFalse(tick(h).changed)
        h.clock.advance(by: 30)
        XCTAssertEqual(tick(h).state.phase, .exercising)
    }

    func testTimedHoldAfterAutoStartStillNeedsUserResult() {
        let late = Harness()
        late.toResting()
        late.clock.advance(by: 90 + 12) // 12 s past the rest deadline: beyond tolerance ⇒ no auto start
        XCTAssertEqual(tick(late).state.phase, .ready)

        let h = Harness()
        h.toResting()
        h.clock.advance(by: 90)
        _ = tick(h)
        h.clock.advance(by: 12)
        let r = tick(h)
        XCTAssertEqual(r.state.phase, .awaitingResult)
        XCTAssertEqual(r.state.confirmedSetCount, 1, "deadline → result form, never a set result")
        XCTAssertTrue(Transition(state: r.state, events: r.events).setRecords.isEmpty)
    }
}
