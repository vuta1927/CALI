import CaliCore
import CaliDomain
import CaliDomainTestSupport
import Foundation
import GRDB
import XCTest

/// IOS-001: one-time import of the pre-GRDB `cali-poc.json` snapshot (docs/19 BR-10 for the plan).
final class LegacySnapshotImporterTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var dir: TempDir!

    override func setUpWithError() throws { dir = try TempDir() }
    override func tearDown() { dir.remove() }

    private var jsonURL: URL { dir.url.appendingPathComponent("cali-poc.json") }

    private func write(_ snapshot: PersistedSnapshot) throws {
        try DomainJSON.makeEncoder().encode(snapshot).write(to: jsonURL)
    }

    private func snapshot(catalog: [Exercise]? = Content.catalog, plan: WorkoutPlan = Content.plan(), active: ActiveSession? = nil) -> PersistedSnapshot {
        PersistedSnapshot(
            catalog: catalog, plan: plan,
            history: [Content.session(401, startedAt: t0.addingTimeInterval(-5 * 86_400)),
                      Content.session(402, startedAt: t0.addingTimeInterval(-9 * 86_400), sample: true)],
            recommendations: [Content.recommendation(500)],
            audit: [AuditEntry(id: uuid(900), at: t0, action: "rename_plan", detail: "x")],
            settings: AppSettings(countdownSeconds: 5, hasSeenWelcome: true), active: active,
            createdAt: t0.addingTimeInterval(-20 * 86_400)
        )
    }

    private func importNow(_ db: any DatabaseWriter, fallback: [Exercise] = Content.catalog) throws -> LegacySnapshotImporter.Outcome {
        try LegacySnapshotImporter.importIfNeeded(fileURL: jsonURL, writer: db, fallbackCatalog: fallback, now: t0, timeZone: utc)
    }

    func testNoFileIsANoOp() throws {
        let db = try CaliDatabase.openInMemory()
        XCTAssertEqual(try importNow(db), .noFile)
        XCTAssertFalse(try ContentStore(writer: db).isInitialized())
    }

    func testImportsEverythingOnceAndKeepsTheFileAsBackup() throws {
        try write(snapshot())
        let db = try CaliDatabase.openInMemory()
        guard case .imported(let summary) = try importNow(db) else { return XCTFail("expected import") }
        XCTAssertEqual(summary.history, 2)
        XCTAssertFalse(summary.usedFallbackCatalog)

        let content = try ContentStore(writer: db).load()
        XCTAssertEqual(content.catalog.map(\.id), Content.catalog.map(\.id))
        XCTAssertEqual(content.plans.map { $0.stripped() }, [Content.plan()])
        XCTAssertEqual(Set(content.history.map(\.id)), [uuid(401), uuid(402)])
        XCTAssertEqual(content.recommendations.count, 1)
        XCTAssertEqual(content.audit.map(\.id), [uuid(900)])
        XCTAssertEqual(content.settings.countdownSeconds, 5)

        let sources = try db.read { try String.fetchAll($0, sql: "SELECT source FROM session_history ORDER BY id") }
        XCTAssertEqual(sources, ["imported", "sample"])

        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("cali-poc.imported.json").path))

        // A second copy of the file (e.g. restored from a backup) is never imported again.
        try write(snapshot(plan: Content.plan(id: uuid(101))))
        XCTAssertEqual(try importNow(db), .alreadyImported)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM training_plans") }, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("cali-poc.imported-1.json").path))
    }

    func testBR10ActivationStartsOnTheFirstRealSession() throws {
        try write(snapshot())
        let db = try CaliDatabase.openInMemory()
        _ = try importNow(db)
        let row = try db.read { try Row.fetchOne($0, sql: "SELECT from_date, to_date FROM plan_activations") }
        // Session 401 started 5 days before t0 (sample 402 is older but ignored).
        XCTAssertEqual(row?["from_date"], "2026-11-02")
        XCTAssertNil(row?["to_date"] as String?)
        let plan = try db.read { try Row.fetchOne($0, sql: "SELECT kind, status, primary_discipline FROM training_plans") }
        XCTAssertEqual(plan?["kind"], "weekly")
        XCTAssertEqual(plan?["status"], "current")
        XCTAssertEqual(plan?["primary_discipline"], "calisthenics")
    }

    func testBR10WithoutSessionsUsesSnapshotCreationDay() throws {
        var s = snapshot()
        s.history = []
        try write(s)
        let db = try CaliDatabase.openInMemory()
        _ = try importNow(db)
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT from_date FROM plan_activations") }, "2026-10-18")
    }

    func testDeletedPlanStaysDeletedWithoutActivation() throws {
        try write(snapshot(plan: Content.plan(deletedAt: t0.addingTimeInterval(-86_400))))
        let db = try CaliDatabase.openInMemory()
        guard case .imported(let summary) = try importNow(db) else { return XCTFail("expected import") }
        XCTAssertTrue(summary.planDeleted)
        XCTAssertNotNil(try ContentStore(writer: db).load().plans.first?.deletedAt)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM plan_activations") }, 0)
    }

    func testSnapshotWithoutCatalogUsesTheFallback() throws {
        try write(snapshot(catalog: nil, plan: Content.plan(exerciseIds: [uuid(7001), uuid(7003)])))
        let db = try CaliDatabase.openInMemory()
        guard case .imported(let summary) = try importNow(db) else { return XCTFail("expected import") }
        XCTAssertTrue(summary.usedFallbackCatalog)
        XCTAssertEqual(try ContentStore(writer: db).load().catalog.count, 3)
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT primary_discipline FROM training_plans") }, "mixed")
    }

    func testMissingReferencedExerciseIsTakenFromTheFallback() throws {
        // User catalog lacks 7002 although the plan uses it.
        try write(snapshot(catalog: [Content.catalog[0]]))
        let db = try CaliDatabase.openInMemory()
        _ = try importNow(db)
        XCTAssertEqual(Set(try ContentStore(writer: db).load().catalog.map(\.id)), [uuid(7001), uuid(7002)])
    }

    func testActiveSessionIsRestoredAndCanContinue() throws {
        // Build a real in-flight state with one confirmed set using the coordinator on a scratch DB.
        let scratch = CoreFixture(writer: try CaliDatabase.openInMemory())
        try scratch.toResting()
        let records = try scratch.coordinator.setResults(sessionId: sessionA)
        try write(snapshot(active: ActiveSession(state: scratch.state, title: "Thứ 2", records: records)))

        let db = try CaliDatabase.openInMemory()
        guard case .imported(let summary) = try importNow(db) else { return XCTFail("expected import") }
        XCTAssertTrue(summary.restoredActiveSession)
        XCTAssertEqual(summary.restoredSetResults, 1)

        let f = CoreFixture(writer: db, clock: FakeClock(now: scratch.clock.now()))
        XCTAssertEqual(f.state, scratch.state)
        XCTAssertEqual(try f.coordinator.activeSessionTitle(), "Thứ 2")
        XCTAssertEqual(try f.coordinator.setResults(sessionId: sessionA), records)
        try f.send(f.readyNext())
        XCTAssertEqual(f.state.phase, .ready)
    }

    func testCorruptFileWritesNothingAndIsMovedAside() throws {
        try Data("{ not json".utf8).write(to: jsonURL)
        let db = try CaliDatabase.openInMemory()
        guard case .unreadable(let moved) = try importNow(db) else { return XCTFail("expected unreadable") }
        XCTAssertEqual(moved, "cali-poc.unreadable-\(Int(t0.timeIntervalSince1970)).json")
        XCTAssertFalse(try ContentStore(writer: db).isInitialized())
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM legacy_imports") }, 0)
    }

    func testFailureDuringImportRollsBackAndKeepsTheFile() throws {
        var s = snapshot()
        s.plan.title = "" // violates the training_plans title CHECK
        try write(s)
        let db = try CaliDatabase.openInMemory()
        XCTAssertThrowsError(try importNow(db))
        XCTAssertFalse(try ContentStore(writer: db).isInitialized())
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM exercises") }, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path), "file kept for the next attempt")
    }
}
