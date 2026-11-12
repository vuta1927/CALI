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

    func testTransitionRestNeverAutoAdvances() {
        let h = Harness()
        create(h, transition: nil)
        h.send(h.skip())
        XCTAssertFalse(h.s.restAutoAdvances)
        h.clock.advance(by: 60)
        let r = h.reconcile(previousNow: h.now.addingTimeInterval(-1), monotonicElapsed: 1, policy: ReconcilePolicy(autoAdvance: true))
        XCTAssertEqual(r.state.phase, .ready, "a new exercise starts only on the user's Start")
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
