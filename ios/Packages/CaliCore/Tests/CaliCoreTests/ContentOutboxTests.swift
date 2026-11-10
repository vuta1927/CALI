import CaliDomain
import CaliDomainTestSupport
import Foundation
import GRDB
import XCTest
@testable import CaliCore

/// IOS-007 slice 3a: content edits become contract-shaped outbox mutations in the same transaction.
final class ContentOutboxTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private func queue() throws -> DatabaseQueue { try CaliDatabase.openInMemory() as! DatabaseQueue }

    private func rows(_ db: DatabaseQueue) throws -> [(type: String, action: String, payload: [String: Any])] {
        try db.read { try Row.fetchAll($0, sql: "SELECT entity_type, action, json FROM sync_outbox WHERE payload_version = 2 ORDER BY seq") }.map { row in
            let envelope = try JSONSerialization.jsonObject(with: Data((row["json"] as String).utf8)) as! [String: Any]
            return (row["entity_type"], row["action"], envelope["payload"] as! [String: Any])
        }
    }

    private func store(_ db: DatabaseQueue) throws -> ContentStore {
        let store = ContentStore(writer: db)
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        return store
    }

    func testSeedAloneQueuesNothingButTheFirstEditQueuesEverythingParentsFirst() throws {
        let db = try queue()
        let store = try store(db)
        XCTAssertTrue(try rows(db).isEmpty, "bundled content is not the user's change")
        var plan = try XCTUnwrap(store.load().plans.first)
        plan.title = "Giáo án của tôi"
        try store.apply(ContentChange(plans: [plan]), now: t0)
        let queued = try rows(db)
        let types = queued.map(\.type)
        XCTAssertEqual(types.first, "training_plan")
        let firstOfType = ["training_plan", "plan_activation", "planned_workout", "planned_exercise"].compactMap { types.firstIndex(of: $0) }
        XCTAssertEqual(firstOfType, firstOfType.sorted(), "parents before children")
        for item in queued {
            XCTAssertEqual(item.action, "upsert")
            PayloadSchema.assertConforms(item.payload, to: item.type + "_payload")
        }
        XCTAssertNil(queued.first { $0.type == "planned_workout" }?.payload["focus"], "focus is not part of the contract")
    }

    func testNothingIsQueuedAgainWhenAPlanSaveChangesNothing() throws {
        let db = try queue()
        let store = try store(db)
        var plan = try XCTUnwrap(store.load().plans.first)
        plan.title = "A"
        try store.apply(ContentChange(plans: [plan]), now: t0)
        let before = try rows(db).count
        try store.apply(ContentChange(plans: [plan]), now: t0.addingTimeInterval(60))
        XCTAssertEqual(try rows(db).count, before)
        plan.title = "B"
        try store.apply(ContentChange(plans: [plan]), now: t0.addingTimeInterval(120))
        let titles = try rows(db).filter { $0.type == "training_plan" }.map { $0.payload["title"] as? String }
        XCTAssertEqual(titles, ["A", "B"], "only the changed plan row, once")
        XCTAssertEqual(try rows(db).count, before + 1)
    }

    func testRemovedWorkoutSendsDeletesChildrenFirstOnlyForEntitiesTheServerMayKnow() throws {
        let db = try queue()
        let store = try store(db)
        var plan = try XCTUnwrap(store.load().plans.first)
        plan.title = "A"
        try store.apply(ContentChange(plans: [plan]), now: t0)
        let removed = plan.workouts[0]
        plan.workouts.removeFirst()
        try store.apply(ContentChange(plans: [plan]), now: t0.addingTimeInterval(60))
        let deletes = try rows(db).filter { $0.action == "delete" }
        XCTAssertEqual(deletes.map(\.type), Array(repeating: "planned_exercise", count: removed.exercises.count) + ["planned_workout"])
        deletes.forEach { PayloadSchema.assertConforms($0.payload, to: "delete_payload") }

        // A workout created and removed before any queueing never reaches the server.
        let ghost = PlannedWorkout(id: UUID(), weekday: 2, title: "Tạm", focus: "", exercises: [])
        var withGhost = plan
        withGhost.workouts.append(ghost)
        try store.apply(ContentChange(plans: [withGhost]), now: t0.addingTimeInterval(120))
        let before = try rows(db).filter { $0.action == "delete" }.count
        try store.apply(ContentChange(plans: [plan]), now: t0.addingTimeInterval(180))
        XCTAssertEqual(try rows(db).filter { $0.action == "delete" }.count, before + 1, "queued once, so its delete is sent")
    }

    func testGoalsPhasesBodyMeasurementsAndSoftDeletesConform() throws {
        let db = try queue()
        let store = try store(db)
        var plan = try XCTUnwrap(store.load().plans.first)
        plan.phases = [PlanPhase(id: UUID(), name: "Nền tảng", weeks: 4, description: "Giữ form")]
        let goal = PlanGoal(id: UUID(), planLineageId: plan.lineageId, title: "10 lần", indicatorId: "best_set_reps", baseline: 6, target: .value(10), pinned: true)
        var body = BodyMeasurement(value: Decimal(string: "72.45")!, measuredAt: t0)
        try store.apply(ContentChange(plans: [plan], goals: [goal], bodyMeasurements: [body]), now: t0)
        let queued = try rows(db)
        for type in ["plan_phase", "plan_goal", "body_measurement"] { XCTAssertTrue(queued.contains { $0.type == type }, type) }
        queued.forEach { PayloadSchema.assertConforms($0.payload, to: $0.type + "_payload") }
        XCTAssertEqual((queued.first { $0.type == "body_measurement" }?.payload["value"] as? NSNumber)?.doubleValue, 72.45)

        body.deletedAt = t0
        try store.apply(ContentChange(bodyMeasurements: [body]), now: t0.addingTimeInterval(60))
        let last = try XCTUnwrap(try rows(db).last)
        XCTAssertEqual(last.type, "body_measurement")
        XCTAssertEqual(last.action, "delete")
        PayloadSchema.assertConforms(last.payload, to: "delete_payload")
    }

    func testAcknowledgementClearsDirtyOnlyWhenTheRowStillMatches() throws {
        let db = try queue()
        let store = try store(db)
        var m = BodyMeasurement(value: 72, measuredAt: t0)
        try store.apply(ContentChange(bodyMeasurements: [m]), now: t0)
        let acked = try rows(db)[0].payload
        m.value = 73
        try store.apply(ContentChange(bodyMeasurements: [m]), now: t0.addingTimeInterval(1))
        try db.write { db in
            let value = try JSONValue.fromAny(acked)
            try ContentOutbox.acknowledge(db, type: "body_measurement", id: m.id, action: "upsert", payload: value)
        }
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT dirty FROM body_measurements") }, 1, "edited after the acknowledged version")
        let latest = try rows(db).last!.payload
        try db.write { try ContentOutbox.acknowledge($0, type: "body_measurement", id: m.id, action: "upsert", payload: try JSONValue.fromAny(latest)) }
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT dirty FROM body_measurements") }, 0)
    }

    /// Sign-in later: rows that were seeded or imported go out with the first sync run.
    func testSyncRunQueuesSeededRowsWhenThereIsAnAccount() async throws {
        let db = try queue()
        _ = try store(db)
        let api = OutboxSyncEngineTests.FakeAPI()
        api.respond = { request in SyncPushResponse(results: request.mutations.map { SyncMutationResult(mutationId: $0.mutationId, status: .applied, serverVersion: 1) }) }
        let summary = await OutboxSyncEngine(writer: db, api: api, clock: { Date(timeIntervalSince1970: 1_800_000_000) }, jitter: { 1 }).syncOnce()
        XCTAssertGreaterThan(summary.acked, 0)
        XCTAssertEqual(api.requests.flatMap(\.mutations).first?.entityType, "training_plan")
        let dirty = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM training_plans WHERE dirty = 1") }
        XCTAssertEqual(dirty, 0, "acknowledged")
    }
}

extension JSONValue {
    /// Test helper: a value read with JSONSerialization.
    static func fromAny(_ any: Any) throws -> JSONValue {
        try DomainJSON.makeDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: any))
    }
}
