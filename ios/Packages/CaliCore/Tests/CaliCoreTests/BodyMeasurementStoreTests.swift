import CaliCore
import CaliDomain
import Foundation
import GRDB
import XCTest

/// IOS-018: body measurements persist exactly, soft-delete, and stay out of audit text.
final class BodyMeasurementStoreTests: XCTestCase {
    private func store() throws -> (ContentStore, any DatabaseWriter) {
        let db = try CaliDatabase.openInMemory()
        return (ContentStore(writer: db), db)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testValueRoundTripsExactlyAndNewestComesFirst() throws {
        let (store, _) = try store()
        let a = BodyMeasurement(value: Decimal(string: "72.4")!, measuredAt: now.addingTimeInterval(-86_400))
        let b = BodyMeasurement(value: Decimal(string: "71.85")!, measuredAt: now)
        try store.apply(ContentChange(bodyMeasurements: [a, b]), now: now)
        let loaded = try store.load().bodyMeasurements
        XCTAssertEqual(loaded.map(\.id), [b.id, a.id])
        XCTAssertEqual(loaded.map(\.value), [Decimal(string: "71.85")!, Decimal(string: "72.4")!], "no float round trip")
        XCTAssertEqual(loaded[0].measuredAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
    }

    func testEditAndSoftDeleteKeepTheRowButHideIt() throws {
        let (store, queue) = try store()
        var m = BodyMeasurement(value: 72, measuredAt: now)
        try store.apply(ContentChange(bodyMeasurements: [m]), now: now)
        m.value = Decimal(string: "72.5")!
        try store.apply(ContentChange(bodyMeasurements: [m]), now: now)
        XCTAssertEqual(try store.load().bodyMeasurements.map(\.value), [Decimal(string: "72.5")!])
        m.deletedAt = now
        try store.apply(ContentChange(bodyMeasurements: [m]), now: now)
        XCTAssertTrue(try store.load().bodyMeasurements.isEmpty)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM body_measurements WHERE dirty = 1 AND deleted_at IS NOT NULL") }, 1,
                       "the soft delete is a dirty row, so sync can carry it")
    }

    func testTheDatabaseRefusesWhatTheContractRefuses() throws {
        let (_, queue) = try store()
        func insert(_ value: String) throws {
            try queue.write { try $0.execute(sql: "INSERT INTO body_measurements (id, kind, value, measured_at, created_at, updated_at) VALUES (?, 'weight', ?, 'x', 'x', 'x')",
                                             arguments: [UUID().uuidString, value]) }
        }
        XCTAssertNoThrow(try insert("72.45"))
        XCTAssertThrowsError(try insert("72.455"), "three decimals")
        XCTAssertThrowsError(try insert("19.9"))
        XCTAssertThrowsError(try insert("500.5"))
        XCTAssertThrowsError(try queue.write { try $0.execute(sql: "INSERT INTO body_measurements (id, kind, value, measured_at, created_at, updated_at) VALUES ('k', 'height', '170', 'x', 'x', 'x')") })
    }
}
