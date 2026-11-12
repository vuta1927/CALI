import CaliCore
import Foundation
import GRDB
import XCTest

/// QA (IOS-023): v8_set_result_tombstones upgrades a v6 database (via v7_rest_between_exercises) holding real rows without loss.
final class QAMigrationV7Tests: XCTestCase {
    func testUpgradeFromV6PreservesRowsAndEnforcesOneLivePerSet() throws {
        let q = try DatabaseQueue(configuration: CaliDatabase.configuration(label: "qa.v6"))
        try CaliDatabase.migrator.migrate(q, upTo: "v6_sync_inbox")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO local_session_state (session_id, status, phase, revision, state_json, updated_at)
                VALUES ('s1', 'completed', 'completed', 9, '{}', '2026-11-01T08:00:00Z');
                INSERT INTO set_results (id, session_id, execution_id, set_index, status, record_json, confirmed_at, revision)
                VALUES ('r1', 's1', 'e1', 1, 'confirmed', '{"a":1}', '2026-11-01T08:01:00Z', 3),
                       ('r2', 's1', 'e1', 2, 'skipped', '{"a":2}', '2026-11-01T08:02:00Z', 4);
                """)
        }
        try CaliDatabase.migrator.migrate(q)
        try q.read { db in
            XCTAssertEqual(try CaliDatabase.migrator.appliedIdentifiers(db).contains("v8_set_result_tombstones"), true)
            let rows = try Row.fetchAll(db, sql: "SELECT id, status, record_json, revision, deleted_at FROM set_results ORDER BY id")
            XCTAssertEqual(rows.map { $0["id"] as String }, ["r1", "r2"])
            XCTAssertEqual(rows.map { $0["record_json"] as String }, ["{\"a\":1}", "{\"a\":2}"])
            XCTAssertEqual(rows.map { $0["revision"] as Int }, [3, 4])
            XCTAssertTrue(rows.allSatisfy { ($0["deleted_at"] as String?) == nil })
            XCTAssertEqual(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count, 0)
        }
        // Live duplicate rejected; after tombstoning, a redo row for the same set is accepted.
        XCTAssertThrowsError(try q.write { db in
            try db.execute(sql: "INSERT INTO set_results (id, session_id, execution_id, set_index, status, record_json, confirmed_at, revision) VALUES ('r3','s1','e1',2,'confirmed','{}','2026-11-01T08:03:00Z',5)")
        })
        try q.write { db in
            try db.execute(sql: "UPDATE set_results SET deleted_at = '2026-11-01T08:03:00Z' WHERE id = 'r2'")
            try db.execute(sql: "INSERT INTO set_results (id, session_id, execution_id, set_index, status, record_json, confirmed_at, revision) VALUES ('r3','s1','e1',2,'confirmed','{}','2026-11-01T08:03:00Z',5)")
        }
        XCTAssertEqual(try q.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM set_results WHERE session_id='s1'") }, 3)
    }
}
