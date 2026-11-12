import CaliCore
import CaliDomain
import CaliDomainTestSupport
import Foundation
import GRDB
import XCTest

/// IOS-023: ReopenSkipped tombstones the skipped results and queues sync deletes in the command's transaction.
final class ReopenSkippedCoordinatorTests: XCTestCase {
    private func skip(_ f: CoreFixture, setResultId: UUID) -> Command {
        let key = f.state.currentSetKey!
        return .skipSet(SkipSet(commandId: f.freshId(), setResultId: setResultId, executionId: key.executionId, setIndex: key.setIndex))
    }

    private func reopen(_ f: CoreFixture, _ executionId: UUID, commandId: UUID? = nil) -> Command {
        .reopenSkipped(ReopenSkipped(commandId: commandId ?? f.freshId(), executionId: executionId))
    }

    func testReopenTombstonesAndQueuesDeleteThenRedoUsesNewId() throws {
        let f = try CoreFixture.inMemory()
        try f.send(f.create([Specs.hold(), Specs.reps()]))
        let skippedId = uuid(4001)
        try f.send(skip(f, setResultId: skippedId))
        XCTAssertEqual(try f.coordinator.counts().setResults, 1)

        let reopenId = uuid(3001)
        let r = try f.send(reopen(f, Specs.hold().id, commandId: reopenId))
        XCTAssertEqual(r.events.map(\.code), ["set_results_retracted"])
        XCTAssertEqual(try f.coordinator.counts().setResults, 0, "tombstoned row is not live")
        XCTAssertEqual(try f.coordinator.setResults(sessionId: sessionA), [])
        let deletedAt = try f.coordinator.writer.read {
            try String.fetchOne($0, sql: "SELECT deleted_at FROM set_results WHERE id = ?", arguments: [skippedId.uuidString.lowercased()])
        }
        XCTAssertNotNil(deletedAt, "soft delete, never a hard delete while unsynced")

        let entries = try f.coordinator.outboxEntries().filter { $0.entityType == "set_result" }
        XCTAssertEqual(entries.map(\.action), ["upsert", "delete"])
        XCTAssertEqual(entries.map(\.entityId), [skippedId, skippedId])
        XCTAssertNil(entries[1].baseVersion, "the sync engine rebases the delete on the acknowledged version")
        XCTAssertNotEqual(entries[0].mutationId, entries[1].mutationId)
        let json = try f.coordinator.writer.read {
            try String.fetchOne($0, sql: "SELECT json FROM sync_outbox WHERE seq = ?", arguments: [entries[1].seq])
        }
        XCTAssertTrue(json?.contains("\"deletedAt\"") == true)
        XCTAssertTrue(json?.contains("\"action\":\"delete\"") == true)

        // Redo the same set under a new id: the partial unique index allows it.
        try f.send(f.startSet())
        f.clock.advance(by: 5)
        try f.send(f.stopSet())
        let redoId = uuid(4002)
        try f.send(f.confirm(setResultId: redoId))
        XCTAssertEqual(try f.coordinator.setResults(sessionId: sessionA).map(\.setResultId), [redoId])
        XCTAssertEqual(try f.coordinator.setResults(sessionId: sessionA).first?.key, SetKey(executionId: Specs.hold().id, setIndex: 1))
    }

    func testSecondReopenIsAlreadyResolvedAndWritesNothing() throws {
        let f = try CoreFixture.inMemory()
        try f.send(f.create([Specs.hold(), Specs.reps()]))
        try f.send(skip(f, setResultId: uuid(4001)))
        try f.send(reopen(f, Specs.hold().id))
        let outbox = try f.coordinator.counts().outbox
        let again = try f.coordinator.handle(reopen(f, Specs.hold().id))
        XCTAssertEqual(again.outcome.status, .alreadyResolved)
        XCTAssertEqual(again.outcome.errorCode, "nothing_to_reopen")
        XCTAssertEqual(try f.coordinator.counts().outbox, outbox)

        // Same commandId replays the stored outcome.
        let cmd = reopen(f, Specs.hold().id, commandId: uuid(3100))
        _ = try f.coordinator.handle(cmd)
        XCTAssertTrue(try f.coordinator.handle(cmd).replayed)
    }

    func testHistoryOfFinishedSessionExcludesTombstones() throws {
        let f = try CoreFixture.inMemory()
        try f.send(f.create([Specs.hold(sets: 1)]))
        try f.send(skip(f, setResultId: uuid(4001)))
        XCTAssertEqual(f.state.phase, .reviewingSummary)
        try f.send(reopen(f, Specs.hold().id))
        try f.send(f.startSet())
        f.clock.advance(by: 5)
        try f.send(f.stopSet())
        try f.send(f.confirm(setResultId: uuid(4002)))
        try f.send(.finishSession(SimpleCommand(commandId: f.freshId())))
        let history = try f.coordinator.writer.read { db in
            try String.fetchOne(db, sql: "SELECT json FROM session_history WHERE id = ?", arguments: [sessionA.uuidString.lowercased()])
        }
        XCTAssertNotNil(history)
        XCTAssertFalse(history!.contains(uuid(4001).uuidString.lowercased()) || history!.contains(uuid(4001).uuidString))
        XCTAssertEqual(try f.coordinator.counts().setResults, 1)
    }
}
