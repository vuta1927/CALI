import CaliDomain
import CaliDomainTestSupport
import Foundation
import GRDB
import XCTest
@testable import CaliCore

private func s(_ text: String) -> JSONValue { .string(text) }
private func n(_ number: Int) -> JSONValue { .number(Decimal(number)) }
private func id(_ number: Int) -> String { uuid(number).uuidString.lowercased() }

/// IOS-007 slice 3b: pulled content is applied to the local tables, and the user's decisions on conflicts.
final class ContentApplyTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    typealias FakeAPI = OutboxSyncEngineTests.FakeAPI

    private func queue() throws -> DatabaseQueue { try CaliDatabase.openInMemory() as! DatabaseQueue }

    private func seeded() throws -> (DatabaseQueue, ContentStore) {
        let db = try queue()
        let store = ContentStore(writer: db)
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        return (db, store)
    }


    private func inbox(_ db: DatabaseQueue, _ type: String, _ entity: UUID, version: Int64 = 1, op: String = "upsert", payload: JSONValue) async throws {
        try await db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO sync_inbox (entity_type, entity_id, operation, server_version, change_id, payload_json, received_at) VALUES (?, ?, ?, ?, 'c', ?, ?)",
                           arguments: [type, DBText.id(entity), op, version, String(decoding: try SyncWireCoding.encoder().encode(payload), as: UTF8.self), DBText.time(t0)])
        }
    }

    private func applyInbox(_ db: DatabaseQueue) async throws -> Int {
        try await db.write { try ContentApplier.applyInbox($0, now: t0) }
    }

    private func remaining(_ db: DatabaseQueue) async throws -> Int {
        try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_inbox") ?? 0 }
    }

    private func planPayload(_ plan: Int, title: String, revision: Int = 1) -> JSONValue {
        .object(["id": s(id(plan)), "title": s(title), "revision": n(revision), "status": s("current"), "lineageId": s(id(plan)), "kind": s("weekly"), "primaryDiscipline": s("calisthenics")])
    }

    func testAPlanWithItsChildrenIsAppliedEvenWhenChildrenArriveFirst() async throws {
        let (db, store) = try seeded()
        try await inbox(db, "planned_exercise", uuid(901), payload: .object([
            "id": s(id(901)), "plannedWorkoutId": s(id(801)), "exerciseId": s(id(7001)), "orderIndex": n(0), "setCount": n(3),
            "target": .object(["kind": s("static_hold"), "holdSeconds": n(30)]), "restSeconds": n(60),
        ]))
        try await inbox(db, "planned_workout", uuid(801), payload: .object(["id": s(id(801)), "planId": s(id(700)), "weekday": n(3), "title": s("Thứ 4"), "orderIndex": n(0)]))
        try await inbox(db, "plan_phase", uuid(851), payload: .object(["id": s(id(851)), "planId": s(id(700)), "orderIndex": n(0), "name": s("Nền tảng"), "weeks": n(4)]))
        try await inbox(db, "training_plan", uuid(700), payload: planPayload(700, title: "Từ máy chủ"))
        let applied = try await applyInbox(db)
        XCTAssertEqual(applied, 4)
        let remainingRows = try await remaining(db)
        XCTAssertEqual(remainingRows, 0)
        let plan = try XCTUnwrap(store.load().plans.first { $0.id == uuid(700) })
        XCTAssertEqual(plan.title, "Từ máy chủ")
        XCTAssertEqual(plan.workouts.first?.exercises.first?.target, .staticHold(holdSeconds: 30))
        XCTAssertEqual(plan.phases.map(\.name), ["Nền tảng"])
        let dirty = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM training_plans WHERE id = ? AND dirty = 1", arguments: [id(700)]) }
        XCTAssertEqual(dirty, 0, "not echoed back")
        let outbox = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }
        XCTAssertEqual(outbox, 0)
    }

    func testAChangeWaitsWhileThisDeviceHasAnEditInFlight() async throws {
        let (db, store) = try seeded()
        var plan = try XCTUnwrap(store.load().plans.first)
        plan.title = "Bản trên máy"
        try store.apply(ContentChange(plans: [plan]), now: t0) // dirty + pending outbox row
        try await inbox(db, "training_plan", uuid(100), version: 5, payload: planPayload(100, title: "Bản máy chủ", revision: 2))
        let applied = try await applyInbox(db)
        XCTAssertEqual(applied, 0)
        XCTAssertEqual(try store.load().plans.first?.title, "Bản trên máy")
        let waiting = try await remaining(db)
        XCTAssertEqual(waiting, 1)
    }

    func testStaleChangeOlderThanAnAcknowledgedVersionIsDropped() async throws {
        let (db, store) = try seeded()
        try await db.write { try $0.execute(sql: "INSERT INTO sync_versions (entity_type, entity_id, server_version) VALUES ('training_plan', ?, 7)", arguments: [id(100)]) }
        try await inbox(db, "training_plan", uuid(100), version: 3, payload: planPayload(100, title: "Cũ"))
        let applied = try await applyInbox(db)
        XCTAssertEqual(applied, 0)
        let left = try await remaining(db)
        XCTAssertEqual(left, 0)
        XCTAssertNotEqual(try store.load().plans.first?.title, "Cũ")
    }

    func testDeleteSoftDeletesAPlanAndRemovesAWorkout() async throws {
        let (db, store) = try seeded()
        try await db.write { db in for table in ["training_plans", "planned_workouts"] { try db.execute(sql: "UPDATE \(table) SET dirty = 0") } } // as if acknowledged
        try await inbox(db, "planned_workout", uuid(200), version: 4, op: "delete", payload: .object(["id": s(id(200)), "deletedAt": s("2026-11-10T00:00:00.000Z")]))
        try await inbox(db, "training_plan", uuid(100), version: 4, op: "delete", payload: .object(["id": s(id(100)), "deletedAt": s("2026-11-10T00:00:00.000Z")]))
        _ = try await applyInbox(db)
        let plan = try XCTUnwrap(store.load().plans.first)
        XCTAssertNotNil(plan.deletedAt)
        XCTAssertTrue(plan.workouts.isEmpty)
    }

    func testAChangeThatDoesNotFitStaysInTheInboxInsteadOfBreakingTheRow() async throws {
        let (db, _) = try seeded()
        try await inbox(db, "planned_exercise", uuid(902), payload: .object([
            "id": s(id(902)), "plannedWorkoutId": s(id(200)), "exerciseId": s(id(7001)), "orderIndex": n(5), "setCount": n(3),
            "target": .object(["kind": s("nonsense")]), "restSeconds": n(60),
        ]))
        try await inbox(db, "planned_exercise", uuid(903), payload: .object([
            "id": s(id(903)), "plannedWorkoutId": s(id(200)), "exerciseId": s(id(9999)), "orderIndex": n(6), "setCount": n(3),
            "target": .object(["kind": s("static_hold"), "holdSeconds": n(30)]), "restSeconds": n(60),
        ]))
        let applied = try await applyInbox(db)
        XCTAssertEqual(applied, 0)
        let left = try await remaining(db)
        XCTAssertEqual(left, 2, "unknown target kind, and an exercise missing from the catalog")
    }

    func testBodyMeasurementAppliesExactlyAndRejectsOutOfRange() async throws {
        let (db, store) = try seeded()
        let good = UUID(), bad = UUID()
        try await inbox(db, "body_measurement", good, payload: .object(["id": s(DBText.id(good)), "kind": s("weight"), "value": .number(Decimal(string: "71.85")!), "measuredAt": s("2026-11-09T07:00:00.000Z")]))
        try await inbox(db, "body_measurement", bad, payload: .object(["id": s(DBText.id(bad)), "kind": s("weight"), "value": .number(Decimal(string: "1000")!), "measuredAt": s("2026-11-09T07:00:00.000Z")]))
        let applied = try await applyInbox(db)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(try store.load().bodyMeasurements.map(\.value), [Decimal(string: "71.85")!])
    }

    func testGoalFromTheServerDecodesIntoThePlanGoalModel() async throws {
        let (db, store) = try seeded()
        let goal = UUID()
        try await inbox(db, "plan_goal", goal, payload: .object([
            "id": s(DBText.id(goal)), "planLineageId": s(id(100)), "title": s("10 lần"), "indicatorId": s("best_set_reps"),
            "target": .object(["value": n(10)]), "status": s("active"), "pinned": .bool(true),
        ]))
        _ = try await applyInbox(db)
        let goals = try store.load().goals
        XCTAssertEqual(goals.map(\.title), ["10 lần"])
        XCTAssertEqual(goals.first?.pinned, true)
    }

    // MARK: Conflict decisions

    private func conflictedBody(_ db: DatabaseQueue, _ store: ContentStore, local: String, server: String) async throws -> (BodyMeasurement, Int64) {
        let m = BodyMeasurement(value: Decimal(string: local)!, measuredAt: t0)
        try store.apply(ContentChange(bodyMeasurements: [m]), now: t0)
        let serverPayload: JSONValue = .object(["id": s(DBText.id(m.id)), "kind": s("weight"), "value": .number(Decimal(string: server)!), "measuredAt": s("2026-11-07T08:00:00.000Z")])
        let api = FakeAPI()
        api.respond = { r in SyncPushResponse(results: r.mutations.map {
            $0.entityType == "body_measurement"
                ? SyncMutationResult(mutationId: $0.mutationId, status: .conflict, serverVersion: 4, serverEntity: serverPayload, error: MutationError(code: "version_conflict", message: "x", retryable: false))
                : SyncMutationResult(mutationId: $0.mutationId, status: .applied, serverVersion: 1)
        }) }
        _ = await OutboxSyncEngine(writer: db, api: api, clock: { t0 }, jitter: { 1 }).syncOnce()
        let seq = try await db.read { try Int64.fetchOne($0, sql: "SELECT seq FROM sync_outbox WHERE state = 'conflicted' AND entity_type = 'body_measurement'") }
        return (m, try XCTUnwrap(seq))
    }

    func testUseServerWritesTheServerValueAndDropsTheLocalChanges() async throws {
        let (db, store) = try seeded()
        let (m, seq) = try await conflictedBody(db, store, local: "72.5", server: "70.25")
        try SyncConflictResolver(writer: db).useServer(seq: seq, now: t0)
        XCTAssertEqual(try store.load().bodyMeasurements.first { $0.id == m.id }?.value, Decimal(string: "70.25")!)
        let states = try await db.read { try String.fetchAll($0, sql: "SELECT state FROM sync_outbox WHERE entity_type = 'body_measurement'") }
        XCTAssertEqual(states, ["discarded"])
        let version = try await db.read { try Int.fetchOne($0, sql: "SELECT server_version FROM sync_versions WHERE entity_id = ?", arguments: [DBText.id(m.id)]) }
        XCTAssertEqual(version, 4)
        XCTAssertEqual(try SyncStatus.read(db).conflicted, 0)
        XCTAssertTrue(try SyncIssue.read(db).isEmpty)
    }

    func testKeepLocalSendsTheSameChangeAgainOnTheServerVersionAsANewMutation() async throws {
        let (db, store) = try seeded()
        let (m, seq) = try await conflictedBody(db, store, local: "72.5", server: "70.25")
        let before = try await db.read { try String.fetchOne($0, sql: "SELECT mutation_id FROM sync_outbox WHERE seq = ?", arguments: [seq]) }
        try SyncConflictResolver(writer: db).keepLocal(seq: seq)
        let api = FakeAPI()
        api.respond = { r in SyncPushResponse(results: r.mutations.map { SyncMutationResult(mutationId: $0.mutationId, status: .applied, serverVersion: 5) }) }
        _ = await OutboxSyncEngine(writer: db, api: api, clock: { t0 }, jitter: { 1 }).syncOnce()
        let sent = try XCTUnwrap(api.requests.flatMap(\.mutations).first { $0.entityType == "body_measurement" })
        XCTAssertNotEqual(DBText.id(sent.mutationId), before)
        XCTAssertEqual(sent.baseVersion, 4)
        XCTAssertEqual(sent.payload["value"], .number(Decimal(string: "72.5")!))
        let state = try await db.read { try String.fetchOne($0, sql: "SELECT state FROM sync_outbox WHERE seq = ?", arguments: [seq]) }
        XCTAssertEqual(state, "acked")
        XCTAssertEqual(try store.load().bodyMeasurements.first { $0.id == m.id }?.value, Decimal(string: "72.5")!)
    }

    func testSessionsAndSetsCannotTakeTheServerVersionButCanKeepTheLocalOne() async throws {
        XCTAssertFalse(SyncConflictResolver.canUseServer(entityType: "set_result"))
        XCTAssertFalse(SyncConflictResolver.canUseServer(entityType: "workout_session"))
        XCTAssertTrue(SyncConflictResolver.canUseServer(entityType: "plan_goal"))
    }

    func testRetryResendsARejectedChangeAndDismissHidesIt() async throws {
        let db = try queue()
        let api = FakeAPI()
        api.respond = { r in SyncPushResponse(results: r.mutations.map {
            SyncMutationResult(mutationId: $0.mutationId, status: .rejected, error: MutationError(code: "active_plan_limit", message: "x", retryable: false))
        }) }
        let (mutation, entity) = (UUID(), UUID())
        let envelope = #"{"mutationId":"\#(DBText.id(mutation))","entityType":"plan_activation","entityId":"\#(DBText.id(entity))","action":"upsert","clientChangedAt":"2026-11-10T00:00:00.000Z","payload":{"id":"x"}}"#
        try await db.write {
            try $0.execute(sql: "INSERT INTO sync_outbox (mutation_id, entity_type, entity_id, action, json, created_at, payload_version) VALUES (?, 'plan_activation', ?, 'upsert', ?, 'x', 2)",
                           arguments: [DBText.id(mutation), DBText.id(entity), envelope])
        }
        let engine = OutboxSyncEngine(writer: db, api: api, clock: { t0 }, jitter: { 1 })
        _ = await engine.syncOnce()
        let seq = try XCTUnwrap(try SyncIssue.read(db).first?.id)
        XCTAssertEqual(try SyncIssue.read(db).first?.code, "active_plan_limit")
        try SyncConflictResolver(writer: db).retry(seq: seq)
        api.respond = { r in SyncPushResponse(results: r.mutations.map { SyncMutationResult(mutationId: $0.mutationId, status: .applied, serverVersion: 1) }) }
        _ = await engine.syncOnce()
        XCTAssertEqual(api.requests.count, 2)
        XCTAssertNotEqual(api.requests[1].mutations[0].mutationId, mutation)

        try await db.write { try $0.execute(sql: "UPDATE sync_outbox SET state = 'rejected'") }
        try SyncConflictResolver(writer: db).dismiss(seq: seq)
        XCTAssertTrue(try SyncIssue.read(db).isEmpty)
        XCTAssertEqual(try SyncStatus.read(db).badge, .synced)
    }

    func testPullAppliesContentThroughTheEngineAndReportsTheCount() async throws {
        let (db, store) = try seeded()
        let api = FakeAPI()
        let goal = UUID()
        let payload: JSONValue = .object(["id": s(DBText.id(goal)), "planLineageId": s(id(100)), "title": s("Từ server"), "indicatorId": s("best_set_reps"),
                                          "target": .object(["value": n(8)]), "status": s("active"), "pinned": .bool(false)])
        api.pullRespond = { cursor in
            cursor == nil ? SyncPullResponse(changes: [SyncChange(changeId: "c1", entityType: "plan_goal", entityId: goal, operation: "upsert", serverVersion: 2, payload: payload)], nextCursor: "c1", hasMore: false)
                          : SyncPullResponse(changes: [], nextCursor: cursor ?? "", hasMore: false)
        }
        let summary = await OutboxSyncEngine(writer: db, api: api, clock: { t0 }, jitter: { 1 }).syncOnce()
        XCTAssertEqual(summary.applied, 1)
        XCTAssertEqual(try store.load().goals.map(\.title), ["Từ server"])
        XCTAssertEqual(try SyncStatus.read(db).unappliedChanges, 0)
    }
}
