import CaliCore
import CaliDomain
import XCTest
@testable import CaliApp

/// IOS-018: body weight is recorded in kg, edited, soft-deleted and kept out of the audit text and settings.
final class BodyMeasurementFlowTests: XCTestCase {
    override func tearDown() {
        Fmt.weightUnit = .kg
        super.tearDown()
    }

    @MainActor
    private func makeStore(database: AppDatabase? = nil) throws -> AppStore {
        let store = AppStore(database: try database ?? AppDatabase.inMemory())
        store.updateSettings { $0.notificationsEnabled = false; $0.liveActivityEnabled = false; $0.countdownSeconds = 0 }
        return store
    }

    private func weight(_ text: String, ago: TimeInterval = 900) -> BodyMeasurement {
        BodyMeasurement(value: Decimal(string: text)!, measuredAt: Date().addingTimeInterval(-ago))
    }

    @MainActor
    func testSaveIsIdempotentAndTheAuditRowNeverCarriesTheNumber() throws {
        let store = try makeStore()
        let m = weight("72.45")
        let command = UUID()
        XCTAssertTrue(store.saveBodyMeasurement(m, commandId: command))
        XCTAssertTrue(store.saveBodyMeasurement(m, commandId: command), "replay is safe")
        XCTAssertEqual(store.weightEntries.map(\.value), [Decimal(string: "72.45")!])
        let rows = store.audit.filter { $0.id == command }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.action, "Thêm số đo cơ thể")
        for text in [rows[0].action, rows[0].detail] {
            XCTAssertFalse(text.contains("72"), "docs/11: the value is not written to the change log")
        }
    }

    @MainActor
    func testSeveralPerDayAreKeptAndAnEditReplacesTheValue() throws {
        let store = try makeStore()
        let morning = weight("72.4", ago: 7200), evening = weight("72.9", ago: 600)
        XCTAssertTrue(store.saveBodyMeasurement(morning))
        XCTAssertTrue(store.saveBodyMeasurement(evening))
        XCTAssertEqual(store.weightEntries.map(\.id), [evening.id, morning.id], "newest first")
        var edited = evening
        edited.value = Decimal(string: "72.7")!
        XCTAssertTrue(store.saveBodyMeasurement(edited))
        XCTAssertEqual(store.weightEntries.first?.value, Decimal(string: "72.7")!)
        XCTAssertEqual(store.weightEntries.count, 2)
        XCTAssertEqual(store.audit.first?.action, "Sửa số đo cơ thể")
    }

    @MainActor
    func testRefusedValuesSaveNothing() throws {
        let store = try makeStore()
        XCTAssertFalse(store.saveBodyMeasurement(weight("72.455")))
        XCTAssertFalse(store.saveBodyMeasurement(weight("19.9")))
        XCTAssertFalse(store.saveBodyMeasurement(weight("500.1")))
        XCTAssertFalse(store.saveBodyMeasurement(weight("72.4", ago: -3600)), "a future time is refused, not clamped")
        XCTAssertTrue(store.weightEntries.isEmpty)
        XCTAssertNotNil(store.alertMessage)
    }

    @MainActor
    func testSoftDeleteHidesTheEntryAndSurvivesARelaunch() throws {
        let database = try AppDatabase.inMemory()
        let store = try makeStore(database: database)
        let a = weight("72.4", ago: 3600), b = weight("71.8")
        XCTAssertTrue(store.saveBodyMeasurement(a))
        XCTAssertTrue(store.saveBodyMeasurement(b))
        XCTAssertTrue(store.deleteBodyMeasurement(a.id))
        XCTAssertEqual(store.weightEntries.map(\.id), [b.id])

        let relaunched = try makeStore(database: database)
        XCTAssertEqual(relaunched.weightEntries.map(\.id), [b.id])
        XCTAssertEqual(relaunched.weightEntries.first?.value, Decimal(string: "71.8")!, "exact decimal after reload")
    }

    @MainActor
    func testBodyWeightStaysInKilogramsWhateverTheLoadUnitIs() throws {
        let store = try makeStore()
        store.updateSettings { $0.weightUnit = .lb }
        XCTAssertEqual(Fmt.bodyKg(Decimal(string: "72.4")!), "72,4 kg")
        XCTAssertEqual(Fmt.loadKg(60), "132,3 lb", "the load unit setting still applies to loads")
        XCTAssertEqual(Fmt.signedBodyKg(Decimal(string: "-0.5")!), "−0,5 kg")
    }

    /// ADR-064: no switch shares body data with the AI; settings carry nothing about it.
    func testThereIsNoShareSettingForBodyData() {
        let labels = Mirror(reflecting: AppSettings()).children.compactMap(\.label).map { $0.lowercased() }
        XCTAssertFalse(labels.contains { $0.contains("body") || $0.contains("share") || $0.contains("weightshare") })
    }
}
