import CaliDomain
import Foundation
import XCTest

/// IOS-022 (PO D2): rest between exercises.
final class TransitionRestTests: XCTestCase {
    private func create(_ h: Harness, transition: Int?) {
        h.send(.createSession(CreateSession(commandId: h.freshId(), sessionId: uuid(5000), executions: [Specs.hold(sets: 1), Specs.reps()],
                                            transitionRestSeconds: transition)))
    }

    func testDefaultIsSixtySeconds() {
        let h = Harness()
        create(h, transition: nil)
        XCTAssertEqual(h.s.transitionRestSeconds, 60)
    }

    func testPlanValueIsUsed() {
        let h = Harness()
        create(h, transition: 30)
        h.send(h.skip())
        XCTAssertEqual(h.s.phase, .resting)
        XCTAssertEqual(h.s.phaseDeadlineAt, h.now.addingTimeInterval(30))
    }

    func testZeroGoesStraightToReady() {
        let h = Harness()
        create(h, transition: 0)
        h.send(h.skip())
        XCTAssertEqual(h.s.phase, .ready)
        XCTAssertEqual(h.s.currentExecutionIndex, 1)
    }

    func testOutOfRangeIsRejected() {
        let h = Harness()
        let e = h.reject(.createSession(CreateSession(commandId: h.freshId(), sessionId: uuid(5000), executions: [Specs.hold()],
                                                      transitionRestSeconds: 3601)))
        XCTAssertEqual(e?.code, "validation_failed")
    }

    /// Interpretation: "a skipped set earns no rest" stays within an exercise; changing exercise always gets the
    /// transition rest.
    func testSkipWithinExerciseHasNoRestButSkipOfLastSetHasTransitionRest() {
        let h = Harness()
        h.send(h.create([Specs.hold(sets: 2), Specs.reps()]))
        h.send(h.skip())
        XCTAssertEqual(h.s.phase, .ready)
        h.send(h.skip())
        XCTAssertEqual(h.s.phase, .resting)
        XCTAssertTrue(h.s.isTransitionRest)
        XCTAssertEqual(h.s.currentExecutionIndex, 1)
    }

    func testIntraExerciseRestIsNotTransition() {
        let h = Harness()
        h.toResting()
        XCTAssertFalse(h.s.isTransitionRest)
        XCTAssertTrue(h.s.restAutoAdvances)
    }

    /// AC3: after the last set of A, the transition rest ends on time → set 1 of B exercising, no SetRecord.
    func testTransitionRestAutoAdvancesToFirstSetOfNextExercise() {
        let h = Harness()
        h.send(h.create([Specs.hold(sets: 1), Specs.hold(sets: 2, id: uuid(9105))]))
        h.send(h.startSet(countdown: 0)); h.clock.advance(by: 12)
        h.send(h.stopSet()); h.send(h.confirm())
        XCTAssertTrue(h.s.isTransitionRest)
        XCTAssertTrue(h.s.restAutoAdvances)
        let deadline = h.s.phaseDeadlineAt!
        h.clock.advance(by: 61)
        let r = h.reconcile(previousNow: h.now.addingTimeInterval(-1), monotonicElapsed: 1, policy: ReconcilePolicy(autoAdvance: true))
        XCTAssertEqual(r.state.phase, .exercising)
        XCTAssertEqual(r.state.currentSetKey, SetKey(executionId: uuid(9105), setIndex: 1))
        XCTAssertEqual(r.state.phaseStartedAt, deadline)
        XCTAssertTrue(r.state.resolvedSets.count == 1, "no SetRecord created by auto-advance")
        XCTAssertFalse(r.events.contains { $0.code == "set_confirmed" || $0.code == "set_skipped" })
    }

    func testLateTransitionRestGoesToReadyWithRestLapsed() {
        let h = Harness()
        create(h, transition: nil)
        h.send(h.skip())
        h.clock.advance(by: 120)
        let r = h.reconcile(previousNow: h.now.addingTimeInterval(-60), monotonicElapsed: 60, policy: ReconcilePolicy(autoAdvance: true))
        XCTAssertEqual(r.state.phase, .ready)
        XCTAssertTrue(r.events.contains { $0.code == "rest_lapsed" })
    }

    func testTransitionRestWithSettingOffEndsInReady() {
        let h = Harness()
        create(h, transition: nil)
        h.send(h.skip())
        h.clock.advance(by: 60)
        let r = h.reconcile(previousNow: h.now.addingTimeInterval(-1), monotonicElapsed: 1, policy: ReconcilePolicy(autoAdvance: false))
        XCTAssertEqual(r.state.phase, .ready)
        XCTAssertFalse(r.events.contains { $0.code == "rest_lapsed" })
    }

    func testFinalExerciseGoesToSummaryWithoutRest() {
        let h = Harness()
        create(h, transition: nil)
        h.send(h.skip())
        h.send(h.readyNext())
        h.send(h.skip())
        h.send(h.skip())
        XCTAssertEqual(h.s.phase, .reviewingSummary)
        XCTAssertNil(h.s.phaseDeadlineAt)
    }

    func testStatePersistedBeforeIOS022DecodesWithDefault() throws {
        let h = Harness()
        create(h, transition: 45)
        var json = try JSONSerialization.jsonObject(with: DomainJSON.makeEncoder().encode(h.s)) as! [String: Any]
        XCTAssertEqual(json["transitionRestSeconds"] as? Int, 45)
        json.removeValue(forKey: "transitionRestSeconds")
        let old = try DomainJSON.makeDecoder().decode(SessionState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.transitionRestSeconds, 60)
        var expected = h.s
        expected.transitionRestSeconds = 60
        XCTAssertEqual(old, expected)
    }
}
