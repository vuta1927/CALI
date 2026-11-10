import CaliCore
import CaliDomain
import Foundation
import GRDB
import XCTest

/// IOS-012: the diagnostics export carries counts and states, never row content or credentials.
final class DiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.c2lnbmF0dXJl"

    func testRedactorRemovesTokensButKeepsOrdinaryText() {
        let text = "GET /v1/plans Authorization: Bearer \(jwt) failed; token=abc123 password: \"hunter2\" retry in 5s"
        let out = LogRedactor.redact(text)
        for secret in [jwt, "abc123", "hunter2"] { XCTAssertFalse(out.contains(secret), secret) }
        XCTAssertTrue(out.contains("GET /v1/plans"))
        XCTAssertTrue(out.contains("retry in 5s"))
        XCTAssertEqual(LogRedactor.redact("Imported legacy snapshot: 3 plans"), "Imported legacy snapshot: 3 plans")
    }

    func testSnapshotCountsRowsDirtyAndOutboxWithoutContent() throws {
        let db = try CaliDatabase.openInMemory()
        let store = ContentStore(writer: db)
        try store.apply(ContentChange(bodyMeasurements: [BodyMeasurement(value: Decimal(string: "72.45")!, measuredAt: now)]), now: now)
        try db.write {
            try $0.execute(sql: """
                INSERT INTO sync_outbox (mutation_id, entity_type, entity_id, action, json, state, attempts, created_at, last_error)
                VALUES ('m1', 'set_result', 'e1', 'upsert', '{"note":"secret note"}', 'failed', 3, '2026-11-10T00:00:00.000Z', 'HTTP 401 token=abc123')
                """)
        }
        let snapshot = try DatabaseDiagnostics.read(db)
        XCTAssertEqual(snapshot.migrations.last, "v4_body_measurements")
        let body = try XCTUnwrap(snapshot.tables.first { $0.name == "body_measurements" })
        XCTAssertEqual(body.rows, 1)
        XCTAssertEqual(body.dirty, 1)
        XCTAssertNil(try XCTUnwrap(snapshot.tables.first { $0.name == "sync_outbox" }).dirty, "no dirty column there")
        let failed = try XCTUnwrap(snapshot.outbox.first)
        XCTAssertEqual([failed.state, "\(failed.count)", "\(failed.maxAttempts)"], ["failed", "1", "3"])
        XCTAssertEqual(failed.lastError, "HTTP 401 ‹redacted›")

        let text = DiagnosticsReport.render(DiagnosticsReport.lines(for: snapshot), generatedAt: now)
        for leaked in ["72.45", "secret note", "abc123"] { XCTAssertFalse(text.contains(leaked), leaked) }
        XCTAssertTrue(text.contains("body_measurements: 1, dirty 1"))
    }
}
