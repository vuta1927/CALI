import CaliDomain
import Foundation
import XCTest

/// IOS-023 (PO D4/D5): reopen skipped sets — "tập lại ngay", then back to where the user was.
final class ReopenSkippedTests: XCTestCase {
    private let a = uuid(9101), b = uuid(9102), c = uuid(9103)

    /// Three exercises of 2 sets: hold A, reps B, hold C.
    private func session() -> Harness {
        let h = Harness()
        h.send(h.create([Specs.hold(sets: 2, id: a), Specs.reps(sets: 2, id: b), Specs.hold(sets: 2, id: c)]))
        return h
    }

    private func doSet(_ h: Harness) {
        if h.s.phase == .resting { h.send(h.readyNext()) }
        h.send(h.startSet(countdown: 0))
        h.clock.advance(by: 5)
        h.send(h.stopSet())
        h.send(h.confirm())
    }

    func testReopenRetractsSkippedResultsAndJumpsToFirstSkippedSet() {
        let h = session()
        let skip1 = h.send(h.skip()).setRecords[0].setResultId // A#1
        let skip2 = h.send(h.skip()).setRecords[0].setResultId // A#2 → transition rest before B
        h.send(h.readyNext())
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: b, setIndex: 1))

        let t = h.send(h.reopen(a))
        XCTAssertEqual(t.events.map(\.code), ["set_results_retracted"]) // ready → ready, no deadline change
        XCTAssertEqual(t.retractedSetResultIds, [skip1, skip2])
        XCTAssertTrue(t.setRecords.isEmpty)
        XCTAssertEqual(h.s.phase, .ready)
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: a, setIndex: 1))
        XCTAssertEqual(h.s.resumePoint, SetKey(executionId: b, setIndex: 1))
        XCTAssertEqual(h.s.skippedSetCount, 0)
    }

    func testDetourReturnsToTheExactSetWithTransitionRest() {
        let h = session()
        h.send(h.skip())                 // A#1 skipped → A#2 ready
        doSet(h)                         // A#2 done → transition rest → B#1
        doSet(h)                         // B#1 done → rest → B#2
        XCTAssertEqual(h.s.phase, .resting)
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: b, setIndex: 2))

        h.send(h.reopen(a))              // from RESTING
        XCTAssertEqual(h.s.phase, .ready)
        XCTAssertNil(h.s.phaseDeadlineAt)
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: a, setIndex: 1))
        XCTAssertEqual(h.s.resumePoint, SetKey(executionId: b, setIndex: 2))

        doSet(h)                         // A#1 done again
        XCTAssertEqual(h.s.phase, .resting)
        XCTAssertTrue(h.s.isTransitionRest)
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: b, setIndex: 2), "back to exactly where the user was")
        XCTAssertNil(h.s.resumePoint)
        XCTAssertEqual(h.s.phaseDeadlineAt, h.now.addingTimeInterval(60))

        doSet(h)                         // B#2 → transition → C#1
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: c, setIndex: 1))
        doSet(h); doSet(h)
        XCTAssertEqual(h.s.phase, .reviewingSummary)
        XCTAssertEqual(h.s.confirmedSetCount, 6)
        h.send(h.finish())
        XCTAssertEqual(h.s.status, .completed)
    }

    /// PO: the transition rest back to the resume point auto-advances like any rest (no set result).
    func testReturnToResumePointAutoAdvances() {
        let h = session()
        h.send(h.skip()); h.send(h.skip())            // A skipped → transition → B#1
        h.send(h.readyNext())
        h.send(h.reopen(a))
        doSet(h)                                      // A#1 → set rest → A#2
        doSet(h)                                      // A#2 → transition rest back to B#1
        XCTAssertTrue(h.s.isTransitionRest)
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: b, setIndex: 1))
        let resolved = h.s.resolvedSets.count
        h.clock.advance(by: 60.5)
        let r = h.reconcile(previousNow: h.now.addingTimeInterval(-0.5), monotonicElapsed: 0.5, policy: ReconcilePolicy(autoAdvance: true))
        XCTAssertEqual(r.state.phase, .exercising)
        XCTAssertEqual(r.state.currentSetKey, SetKey(executionId: b, setIndex: 1))
        XCTAssertEqual(r.state.resolvedSets.count, resolved, "auto-advance never creates a set result")
    }

    func testReopenOnlyRevisitsSkippedSetsOfThatExercise() {
        let h = Harness()
        h.send(h.create([Specs.hold(sets: 3, id: a), Specs.reps(sets: 1, id: b)]))
        h.send(h.skip())                 // A#1
        doSet(h)                         // A#2 → rest → A#3
        h.send(h.readyNext())
        h.send(h.skip())                 // A#3 → transition → B#1
        h.send(h.reopen(a))
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: a, setIndex: 1))
        doSet(h)                         // A#1 → A#3 (A#2 already confirmed), with set rest
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: a, setIndex: 3))
        XCTAssertFalse(h.s.isTransitionRest)
        doSet(h)                         // A#3 → resume B#1
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: b, setIndex: 1))
        XCTAssertNil(h.s.resumePoint)
    }

    func testRepeatedReopenIsIdempotent() {
        let h = session()
        h.send(h.skip())
        h.send(h.reopen(a))
        let before = h.s
        let e = h.reject(h.reopen(a))
        XCTAssertEqual(e, .nothingToReopen(executionId: a))
        XCTAssertEqual(h.s, before)
    }

    func testReopenFromSummaryThenBackToSummary() {
        let h = session()
        h.send(h.skip()); h.send(h.skip())            // A skipped
        h.send(h.readyNext())
        doSet(h); doSet(h)                            // B
        doSet(h); doSet(h)                            // C → summary
        XCTAssertEqual(h.s.phase, .reviewingSummary)
        XCTAssertEqual(h.s.executionsWithSkippedSets.map(\.id), [a])

        h.send(h.reopen(a))
        XCTAssertEqual(h.s.status, .active)
        XCTAssertEqual(h.s.phase, .ready)
        XCTAssertNil(h.s.resumePoint, "nothing to return to from the summary")
        doSet(h)
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: a, setIndex: 2))
        doSet(h)
        XCTAssertEqual(h.s.phase, .reviewingSummary)
        XCTAssertEqual(h.s.skippedSetCount, 0)
        XCTAssertEqual(h.s.confirmedSetCount, 6)
    }

    func testRejectedWhileASetRunsOrAwaitsItsResult() {
        for phase in [Phase.preCountdown, .exercising, .paused, .awaitingResult] {
            let h = session()
            h.send(h.skip())
            switch phase {
            case .preCountdown: h.send(h.startSet())
            case .exercising: h.send(h.startSet(countdown: 0))
            case .paused: h.send(h.startSet(countdown: 0)); h.clock.advance(by: 1); h.send(h.pause())
            default: h.send(h.startSet(countdown: 0)); h.clock.advance(by: 1); h.send(h.stopSet())
            }
            XCTAssertEqual(h.reject(h.reopen(a)), .invalidTransition(from: phase, command: .reopenSkipped), "\(phase)")
        }
    }

    func testFinishedSessionRejects() {
        let h = Harness()
        h.toCompleted()
        let id = h.s.executions[0].id
        XCTAssertEqual(h.reject(h.reopen(id)), .sessionNotActive(.completed))
        let g = Harness()
        g.toAbandoned()
        XCTAssertEqual(g.reject(g.reopen(g.s.executions[0].id)), .sessionNotActive(.abandoned))
    }

    func testUnknownExecutionIsAValidationError() {
        let h = session()
        h.send(h.skip())
        XCTAssertEqual(h.reject(h.reopen(uuid(1)))?.code, "validation_failed")
    }

    func testReopenOfCurrentExerciseDoesNotSetResumePointToARetractedSet() {
        let h = session()
        h.send(h.skip())                 // A#1 → A#2 ready (snackbar undo case)
        h.send(h.reopen(a))
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: a, setIndex: 1))
        XCTAssertEqual(h.s.resumePoint, SetKey(executionId: a, setIndex: 2))
        doSet(h)                         // A#1 → A#2 with set rest, resume point reached and cleared
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: a, setIndex: 2))
        XCTAssertEqual(h.s.phase, .resting)
        XCTAssertNil(h.s.resumePoint)
    }

    func testNestedReopenKeepsTheOriginalResumePoint() {
        let h = session()
        h.send(h.skip()); h.send(h.skip())            // A skipped → transition
        h.send(h.readyNext())
        h.send(h.skip())                              // B#1 skipped → B#2
        doSet(h)                                      // B#2 → transition → C#1
        h.send(h.readyNext())
        h.send(h.reopen(b))                           // resume C#1
        XCTAssertEqual(h.s.resumePoint, SetKey(executionId: c, setIndex: 1))
        h.send(h.reopen(a))                           // still resume at C#1
        XCTAssertEqual(h.s.resumePoint, SetKey(executionId: c, setIndex: 1))
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: a, setIndex: 1))
        doSet(h); doSet(h)                            // A done → back to C#1 (B#1 still unresolved, picked later)
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: c, setIndex: 1))
        doSet(h); doSet(h)                            // C done → wraps to B#1
        XCTAssertEqual(h.s.currentSetKey, SetKey(executionId: b, setIndex: 1))
        doSet(h)
        XCTAssertEqual(h.s.phase, .reviewingSummary)
        XCTAssertEqual(h.s.confirmedSetCount, 6)
    }

    func testResumePointRoundTripsAndOldStatesDecodeWithout() throws {
        let h = session()
        h.send(h.skip())
        h.send(h.reopen(a))
        let data = try DomainJSON.makeEncoder().encode(h.s)
        XCTAssertEqual(try DomainJSON.makeDecoder().decode(SessionState.self, from: data), h.s)
    }
}
