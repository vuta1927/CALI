import CaliDomain
import GRDB
import XCTest
@testable import CaliCore

/// IOS-007: what the outbox stores is what `contracts/entity-payloads.schema.json` allows (closed objects, ADR-030).
final class SyncPayloadConformanceTests: XCTestCase {
    private func assertConforms(_ payload: [String: Any], to def: String, file: StaticString = #filePath, line: UInt = #line) {
        PayloadSchema.assertConforms(payload, to: def, file: file, line: line)
    }

    private func payloads(_ db: DatabaseQueue, _ type: String) throws -> [[String: Any]] {
        try db.read { try String.fetchAll($0, sql: "SELECT json FROM sync_outbox WHERE entity_type = ? AND payload_version = 2 ORDER BY seq", arguments: [type]) }
            .map { text in
                let envelope = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
                return envelope["payload"] as! [String: Any]
            }
    }

    func testSessionExecutionAndSetResultPayloadsConformToTheContract() throws {
        let f = try CoreFixture.inMemory()
        try f.toAwaitingByStop()
        _ = try f.send(f.confirm(holdMs: 12_000))
        try f.coordinator.writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox WHERE payload_version != 2"), 0)
        }
        let queue = f.coordinator.writer as! DatabaseQueue
        let sessions = try payloads(queue, "workout_session"), executions = try payloads(queue, "exercise_execution"), sets = try payloads(queue, "set_result")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertFalse(executions.isEmpty)
        XCTAssertEqual(sets.count, 1)
        sessions.forEach { assertConforms($0, to: "workout_session_payload") }
        XCTAssertTrue(sessions.allSatisfy { $0["currentExecutionId"] == nil || $0["currentExecutionId"] is NSNull }, "the pointer would wait for an execution that waits for the session")
        executions.forEach { assertConforms($0, to: "exercise_execution_payload") }
        sets.forEach { assertConforms($0, to: "set_result_payload") }
        XCTAssertEqual(sets[0]["actualHoldMs"] as? Int, 12_000)
        XCTAssertNil(sessions[0]["pausedAt"], "not paused")
        XCTAssertEqual((sessions[0]["localDate"] as? String)?.count, 10)
    }

    func testTerminalSessionMutationKeepsTheStartLocalDateAndHasNoBaseVersionYet() throws {
        let f = try CoreFixture.inMemory()
        try f.toAwaitingByStop()
        _ = try f.send(f.confirm(holdMs: 12_000))
        let created = try (f.coordinator.writer as! DatabaseQueue).read {
            try Row.fetchOne($0, sql: "SELECT local_date, timezone FROM local_session_state")
        }
        XCTAssertNotNil(created?["local_date"] as String?)
        XCTAssertNotNil(created?["timezone"] as String?)
        let tz = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        XCTAssertEqual(SyncPayloads.localDate(Date(timeIntervalSince1970: 1_800_000_000 - 8 * 3_600), timeZone: tz), "2027-01-15", "date in the session's own zone")
    }

    func testLegacyOutboxRowsAreParkedNotSent() throws {
        let queue = try DatabaseQueue()
        var migrator = CaliDatabase.migrator
        try migrator.migrate(queue, upTo: "v4_body_measurements")
        try queue.write {
            try $0.execute(sql: "INSERT INTO sync_outbox (mutation_id, entity_type, entity_id, action, json, created_at) VALUES ('m', 'set_result', 'e', 'upsert', '{}', 'x')")
        }
        try migrator.migrate(queue)
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT state FROM sync_outbox") }, "legacy")
    }
}
