import CaliCore
import CaliDomain
import CaliDomainTestSupport
import Foundation
import GRDB
import XCTest

/// POC-002: single-writer coordinator semantics (docs/03 §6 pipeline, §7 edge cases).
final class CoordinatorTests: XCTestCase {
    // MARK: Schema

    func testMigrationIsIdempotentAcrossReopen() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        do {
            let pool = try CaliDatabase.openPool(at: dir.dbURL)
            XCTAssertEqual(try pool.read { try CaliDatabase.migrator.appliedIdentifiers($0) }, ["v1", "v2_content"])
        }
        let reopened = try CaliDatabase.openPool(at: dir.dbURL)
        XCTAssertEqual(try reopened.read { try CaliDatabase.migrator.appliedIdentifiers($0) }, ["v1", "v2_content"])
        let mode = try reopened.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        XCTAssertEqual(mode?.lowercased(), "wal")
    }

    func testDatabaseAllowsOnlyOneActiveSession() throws {
        let f = try CoreFixture.inMemory()
        try f.send(f.create())
        let second = try f.coordinator.handle(f.create(sessionId: uuid(5001)))
        XCTAssertEqual(second.outcome.status, .rejected)
        XCTAssertEqual(second.outcome.errorCode, "active_session_exists")
        // The partial unique index enforces it below the reducer too.
        XCTAssertThrowsError(try f.coordinator.writer.write { db in
            try db.execute(sql: """
                INSERT INTO local_session_state (session_id, status, phase, revision, state_json, updated_at)
                VALUES ('x', 'active', 'ready', 1, '{}', '2026-11-07T08:00:00.000Z')
                """)
        })
        XCTAssertEqual(try f.coordinator.counts().sessions, 1)
    }

    // MARK: Dedupe by commandId

    func testSameCommandIdIsAppliedOnceAndReplayed() throws {
        let f = try CoreFixture.inMemory()
        try f.send(f.create())
        let start = f.startSet()
        let first = try f.send(start)
        f.clock.advance(by: 1)
        let again = try f.coordinator.handle(start)

        XCTAssertTrue(again.replayed)
        XCTAssertEqual(again.outcome, first.outcome, "replay returns the stored outcome verbatim")
        XCTAssertEqual(again.events, [])
        XCTAssertEqual(f.state.revision, first.outcome.revision)
        XCTAssertEqual(try f.coordinator.counts().processedCommands, 2)
    }

    func testRejectedCommandIsRecordedAndReplayedWithSameAnswer() throws {
        let f = try CoreFixture.inMemory()
        try f.send(f.create())
        let extend = f.extendRest() // not allowed in `ready`
        let first = try f.coordinator.handle(extend)
        XCTAssertEqual(first.outcome.status, .rejected)
        XCTAssertEqual(first.outcome.errorCode, "invalid_transition")
        XCTAssertEqual(f.state.revision, 1, "rejection leaves state untouched")

        let again = try f.coordinator.handle(extend)
        XCTAssertTrue(again.replayed)
        XCTAssertEqual(again.outcome, first.outcome)
        let counts = try f.coordinator.counts()
        XCTAssertEqual(counts.outbox, 1, "only the create_session outbox row")
        XCTAssertEqual(counts.processedCommands, 2)

        let recent = try f.coordinator.recentOutcomes(limit: 5)
        XCTAssertEqual(recent.map(\.kind), ["extend_rest", "create_session"], "newest first, replay not re-recorded")
        XCTAssertEqual(recent.first, first.outcome)
    }

    // MARK: T-04 double confirm

    func testT04DoubleConfirmWithSameCommandIdWritesOneSetResult() throws {
        let f = try CoreFixture.inMemory()
        try f.toAwaitingByStop()
        let confirm = f.confirm(holdMs: 5_000)
        let first = try f.send(confirm)
        let second = try f.coordinator.handle(confirm)

        XCTAssertTrue(second.replayed)
        XCTAssertEqual(second.outcome.setResultIds, first.outcome.setResultIds)
        try assertOneSetResult(f)
    }

    func testT04DoubleConfirmWithDifferentCommandIdsReturnsExistingResult() throws {
        let f = try CoreFixture.inMemory()
        try f.toAwaitingByStop()
        let key = f.state.currentSetKey!
        let first = try f.send(f.confirm(holdMs: 5_000))
        let firstId = try XCTUnwrap(first.outcome.setResultIds.first)

        // A second UI tap built from the same (now stale) screen: new commandId and new setResultId.
        let stale = Command.confirmSet(ConfirmSet(commandId: f.freshId(), setResultId: f.freshId(), executionId: key.executionId,
                                                  setIndex: key.setIndex, actualHoldMs: 5_000))
        let second = try f.coordinator.handle(stale)
        XCTAssertFalse(second.replayed)
        XCTAssertEqual(second.outcome.status, .alreadyResolved)
        XCTAssertEqual(second.outcome.setResultIds, [firstId], "points at the canonical set result")
        try assertOneSetResult(f)
    }

    // MARK: Concurrency (double tap racing on two connections)

    func testConcurrentSameCommandFromTwoConnectionsAppliesExactlyOnce() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let f = CoreFixture(writer: try CaliDatabase.openPool(at: dir.dbURL))
        try f.toAwaitingByStop()
        let confirm = f.confirm(holdMs: 5_000)

        // Two independent pools on the same file ≈ two writers; BEGIN IMMEDIATE + busy timeout serialise them.
        let other = WorkoutCoordinator(writer: try CaliDatabase.openPool(at: dir.dbURL, label: "second"), clock: f.clock)
        let coordinators = [f.coordinator, other]
        let results = Collector<Result<HandleResult, any Error>>()
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            results.append(Result { try coordinators[i % 2].handle(confirm) })
        }

        let handled = try results.all.map { try $0.get() }
        XCTAssertEqual(handled.count, 8)
        XCTAssertEqual(handled.filter { !$0.replayed }.count, 1, "exactly one application")
        XCTAssertTrue(handled.allSatisfy { $0.outcome.status == .applied })
        XCTAssertTrue(handled.allSatisfy { $0.outcome == handled[0].outcome }, "every caller sees the same outcome")
        try assertOneSetResult(f)
    }

    func testConcurrentConfirmsWithDifferentCommandIdsResolveTheSetOnce() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let f = CoreFixture(writer: try CaliDatabase.openPool(at: dir.dbURL))
        try f.toAwaitingByStop()
        let commands = (0..<6).map { _ in f.confirm(holdMs: 5_000) }

        let results = Collector<Result<HandleResult, any Error>>()
        let coordinator = f.coordinator
        DispatchQueue.concurrentPerform(iterations: commands.count) { i in
            results.append(Result { try coordinator.handle(commands[i]) })
        }
        let handled = try results.all.map { try $0.get() }
        XCTAssertEqual(handled.filter { $0.outcome.status == .applied }.count, 1)
        XCTAssertEqual(handled.filter { $0.outcome.status == .alreadyResolved }.count, commands.count - 1)
        let applied = try XCTUnwrap(handled.first { $0.outcome.status == .applied })
        XCTAssertTrue(handled.allSatisfy { $0.outcome.setResultIds == applied.outcome.setResultIds })
        try assertOneSetResult(f)
    }

    // MARK: Atomicity

    func testFailureInsideTransactionRollsBackEveryWrite() throws {
        let f = try CoreFixture.inMemory()
        try f.toAwaitingByStop()
        let before = f.state
        let countsBefore = try f.coordinator.counts()
        let clashingId = f.freshId()
        // Pre-existing row with the same primary key makes the set_results INSERT fail mid-pipeline,
        // after the session UPDATE already ran inside the transaction.
        try f.coordinator.writer.write { db in
            try db.execute(sql: """
                INSERT INTO set_results (id, session_id, execution_id, set_index, status, record_json, confirmed_at, revision)
                VALUES (?, ?, 'other', 99, 'completed', '{}', '2026-11-07T08:00:00.000Z', 1)
                """, arguments: [clashingId.uuidString.lowercased(), sessionA.uuidString.lowercased()])
        }
        let confirm = f.confirm(setResultId: clashingId, holdMs: 5_000)
        XCTAssertThrowsError(try f.coordinator.handle(confirm))

        XCTAssertEqual(f.state, before, "session state rolled back")
        XCTAssertNil(try f.coordinator.processedOutcome(commandId: confirm.commandId), "not marked processed")
        var expected = countsBefore
        expected.setResults += 1 // only the manually inserted clash row
        XCTAssertEqual(try f.coordinator.counts(), expected)
    }

    // MARK: T-09 kill after confirm

    func testT09ReopenAfterConfirmResumesFromDurableStateWithoutDuplicate() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let clock = FakeClock(now: t0)
        var confirm: Command!
        var stateBeforeKill: SessionState!
        var countsBeforeKill: StoreCounts!
        do {
            let f = CoreFixture(writer: try CaliDatabase.openPool(at: dir.dbURL), clock: clock)
            try f.toAwaitingByStop()
            confirm = f.confirm(holdMs: 5_000)
            try f.send(confirm)
            stateBeforeKill = f.state
            countsBeforeKill = try f.coordinator.counts()
        } // pool released ≈ process killed after COMMIT

        clock.sleep(for: 600)
        let relaunched = WorkoutCoordinator(writer: try CaliDatabase.openPool(at: dir.dbURL), clock: clock)
        XCTAssertEqual(try relaunched.activeState(), stateBeforeKill)
        XCTAssertEqual(try relaunched.counts(), countsBeforeKill)

        // The UI retries the in-flight command after relaunch: replayed, nothing new written.
        let retry = try relaunched.handle(confirm)
        XCTAssertTrue(retry.replayed)
        XCTAssertEqual(try relaunched.counts(), countsBeforeKill)

        // Rest expired while killed: reconcile on relaunch moves to ready; no set result is invented.
        let r = try XCTUnwrap(try relaunched.reconcile(previousNow: nil, monotonicElapsed: nil))
        XCTAssertEqual(r.state.phase, .ready)
        XCTAssertEqual(try relaunched.counts().setResults, 1)
    }

    func testCompletingSessionWritesTerminalOutboxRowOnce() throws {
        let f = try CoreFixture.inMemory()
        try f.toAwaitingByStop([Specs.hold(sets: 1)])
        try f.send(f.confirm(holdMs: 5_000))
        XCTAssertEqual(f.state.phase, .reviewingSummary)
        let finish = Command.finishSession(SimpleCommand(commandId: f.freshId()))
        try f.send(finish)
        _ = try f.coordinator.handle(finish)
        XCTAssertNil(try f.coordinator.activeState())

        let sessionRows = try f.coordinator.outboxEntries().filter { $0.entityType == "workout_session" }
        XCTAssertEqual(sessionRows.map(\.baseVersion), [0, nil], "create + terminal upsert, no duplicate on replay")
        XCTAssertEqual(try f.coordinator.state(sessionId: sessionA)?.status, .completed)
    }

    // MARK: Helpers

    private func assertOneSetResult(_ f: CoreFixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try f.coordinator.setResults(sessionId: sessionA).count, 1, "one set_result", file: file, line: line)
        let setOutbox = try f.coordinator.outboxEntries().filter { $0.entityType == "set_result" }
        XCTAssertEqual(setOutbox.count, 1, "one set_result outbox row", file: file, line: line)
        XCTAssertEqual(f.state.resolvedSets.count, 1, file: file, line: line)
    }
}
