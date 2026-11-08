import CaliCore
import CaliDomain
import CaliDomainTestSupport
import Foundation
import XCTest

/// POC-001/002: Lock Screen / Dynamic Island buttons go through the same coordinator (ADR-013).
final class LiveActivityCommandTests: XCTestCase {
    func testDeterministicIdsAreStableAndRfc9562Version8() {
        let a = CommandIdentity.liveActivityCommandId(sessionId: sessionA, revision: 7, action: .confirmCurrentSet)
        let b = CommandIdentity.liveActivityCommandId(sessionId: sessionA, revision: 7, action: .confirmCurrentSet)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, CommandIdentity.liveActivityCommandId(sessionId: sessionA, revision: 8, action: .confirmCurrentSet))
        XCTAssertNotEqual(a, CommandIdentity.liveActivityCommandId(sessionId: sessionA, revision: 7, action: .extendRest30))
        XCTAssertNotEqual(a, CommandIdentity.liveActivityCommandId(sessionId: uuid(5001), revision: 7, action: .confirmCurrentSet))

        let text = a.uuidString.lowercased()
        let chars = Array(text)
        XCTAssertEqual(chars[14], "8", "version nibble")
        XCTAssertTrue("89ab".contains(chars[19]), "RFC 9562 variant")
        // Golden value (independently computed with a Python FNV-1a reference): must never change, otherwise
        // in-flight Live Activity taps lose dedupe across an app update.
        XCTAssertEqual(CommandIdentity.uuid(namespace: "test", ["a", "b"]), UUID(uuidString: "1FA92332-15A5-8D1C-B04E-7D8CB56610B1"))
        XCTAssertNotEqual(CommandIdentity.uuid(namespace: "test", ["a|b"]), CommandIdentity.uuid(namespace: "test", ["a", "b", "c"]))
    }

    func testConfirmFromLockScreenAfterPromptDeadlineAppliesOnceForDoubleTap() throws {
        let f = try CoreFixture.inMemory()
        try f.toAwaitingAfterDeadline()
        let rendered = f.state.revision
        let key = f.state.pendingResult!.key

        let first = try f.coordinator.handleLiveActivityAction(sessionId: sessionA, renderedRevision: rendered, action: .confirmCurrentSet)
        XCTAssertEqual(first.outcome.status, .applied)
        XCTAssertEqual(first.outcome.setResultIds,
                       [CommandIdentity.setResultId(sessionId: sessionA, executionId: key.executionId, setIndex: key.setIndex)])
        XCTAssertEqual(f.state.phase, .resting)

        // Second tap on the same rendered snapshot (before the activity re-rendered).
        let second = try f.coordinator.handleLiveActivityAction(sessionId: sessionA, renderedRevision: rendered, action: .confirmCurrentSet)
        XCTAssertTrue(second.replayed)
        XCTAssertEqual(second.outcome, first.outcome)

        let records = try f.coordinator.setResults(sessionId: sessionA)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.actual.holdMs, 12_000, "suggested actual from the prompt deadline")
        XCTAssertEqual(try f.coordinator.outboxEntries().filter { $0.entityType == "set_result" }.count, 1)
    }

    func testStaleSnapshotIsRejectedWithoutTouchingState() throws {
        let f = try CoreFixture.inMemory()
        try f.toResting()
        let old = f.state.revision - 1 // snapshot rendered before the confirm
        let before = f.state

        let r = try f.coordinator.handleLiveActivityAction(sessionId: sessionA, renderedRevision: old, action: .extendRest30)
        XCTAssertEqual(r.outcome.status, .rejected)
        XCTAssertEqual(r.outcome.errorCode, "stale_view")
        XCTAssertEqual(f.state, before)
    }

    func testExtendRestDoubleTapExtendsOnce() throws {
        let f = try CoreFixture.inMemory()
        try f.toResting()
        let rendered = f.state.revision
        let deadline = try XCTUnwrap(f.state.phaseDeadlineAt)

        let first = try f.coordinator.handleLiveActivityAction(sessionId: sessionA, renderedRevision: rendered, action: .extendRest30)
        XCTAssertEqual(first.outcome.status, .applied)
        f.clock.advance(by: 0.3)
        let second = try f.coordinator.handleLiveActivityAction(sessionId: sessionA, renderedRevision: rendered, action: .extendRest30)
        XCTAssertTrue(second.replayed)
        XCTAssertEqual(f.state.phaseDeadlineAt, deadline.addingTimeInterval(30))
        XCTAssertEqual(first.outcome.phaseDeadlineAt, deadline.addingTimeInterval(30))

        // A deliberate tap after the activity re-rendered (new revision) extends again.
        let third = try f.coordinator.handleLiveActivityAction(sessionId: sessionA, renderedRevision: f.state.revision, action: .extendRest30)
        XCTAssertEqual(third.outcome.status, .applied)
        XCTAssertEqual(f.state.phaseDeadlineAt, deadline.addingTimeInterval(60))
    }

    func testConfirmNeedsAppForRepsTarget() throws {
        let f = try CoreFixture.inMemory()
        try f.toAwaitingByStop([Specs.reps()])
        let r = try f.coordinator.handleLiveActivityAction(sessionId: sessionA, renderedRevision: f.state.revision, action: .confirmCurrentSet)
        XCTAssertEqual(r.outcome.status, .rejected)
        XCTAssertEqual(r.outcome.errorCode, "needs_app", "reps must be entered in the app")
        XCTAssertEqual(f.state.phase, .awaitingResult)
        XCTAssertEqual(try f.coordinator.counts().setResults, 0)
    }

    func testConfirmNeedsAppForLoadTarget() throws {
        let f = try CoreFixture.inMemory()
        try f.toAwaitingByStop([Specs.load()])
        let r = try f.coordinator.handleLiveActivityAction(sessionId: sessionA, renderedRevision: f.state.revision, action: .confirmCurrentSet)
        XCTAssertEqual(r.outcome.status, .rejected)
        XCTAssertEqual(r.outcome.errorCode, "needs_app", "reps and kg must be entered in the app")
        XCTAssertEqual(f.state.phase, .awaitingResult)
        XCTAssertEqual(try f.coordinator.counts().setResults, 0)
    }

    func testConfirmNeedsAppWhenDeadlineWasReconciledLate() throws {
        // Device locked past the deadline: no suggested actual (user may have stopped earlier) ⇒ no inference.
        let f = try CoreFixture.inMemory()
        try f.toExercising()
        f.clock.sleep(for: 60)
        _ = try f.coordinator.reconcile(previousNow: nil, monotonicElapsed: nil)
        XCTAssertEqual(f.state.phase, .awaitingResult)
        XCTAssertNil(f.state.pendingResult?.suggestedActualMs)

        let r = try f.coordinator.handleLiveActivityAction(sessionId: sessionA, renderedRevision: f.state.revision, action: .confirmCurrentSet)
        XCTAssertEqual(r.outcome.errorCode, "needs_app")
        XCTAssertEqual(try f.coordinator.counts().setResults, 0)
    }

    func testConfirmOutsideAwaitingResultNeedsApp() throws {
        let f = try CoreFixture.inMemory()
        try f.toExercising() // countdown reaching zero is never completion
        let r = try f.coordinator.handleLiveActivityAction(sessionId: sessionA, renderedRevision: f.state.revision, action: .confirmCurrentSet)
        XCTAssertEqual(r.outcome.errorCode, "needs_app")
        XCTAssertEqual(f.state.phase, .exercising)
    }

    func testUnknownSessionIsRejected() throws {
        let f = try CoreFixture.inMemory()
        let r = try f.coordinator.handleLiveActivityAction(sessionId: uuid(4242), renderedRevision: 1, action: .extendRest30)
        XCTAssertEqual(r.outcome.errorCode, "no_session")
        XCTAssertEqual(try f.coordinator.counts().processedCommands, 1)
    }
}
