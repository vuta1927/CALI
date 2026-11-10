import CaliDomain
import GRDB
import XCTest
@testable import CaliCore

/// IOS-007 slice 2: pull side of docs/08 §7 and §9 against a fake `SyncAPI`.
private func change(_ id: String, _ type: String, entity: UUID = UUID(), version: Int64 = 1, op: String = "upsert", payload: JSONValue = .object(["id": .string("x")])) -> SyncChange {
    SyncChange(changeId: id, entityType: type, entityId: entity, operation: op, serverVersion: version, payload: payload)
}

final class PullSyncTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    typealias FakeAPI = OutboxSyncEngineTests.FakeAPI

    private func engine(_ db: DatabaseQueue, _ api: FakeAPI) -> OutboxSyncEngine {
        OutboxSyncEngine(writer: db, api: api, clock: { [t0] in t0 }, jitter: { 1 })
    }

    private func queue() throws -> DatabaseQueue { try CaliDatabase.openInMemory() as! DatabaseQueue }

    private func cursor(_ db: DatabaseQueue) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT cursor FROM sync_cursor WHERE scope = 'main'") }
    }

    func testInitialPullHasNoCursorAndEachPageIsSavedBeforeTheNext() async throws {
        let db = try queue()
        let api = FakeAPI()
        api.pullRespond = { cursor in
            switch cursor {
            case nil: SyncPullResponse(changes: [change("c1", "training_plan"), change("c2", "planned_workout")], nextCursor: "c2", hasMore: true)
            case "c2": SyncPullResponse(changes: [change("c3", "planned_exercise")], nextCursor: "c3", hasMore: false)
            default: SyncPullResponse(changes: [], nextCursor: cursor ?? "", hasMore: false)
            }
        }
        let summary = await engine(db, api).syncOnce()
        XCTAssertEqual(api.pulls, [nil, "c2"])
        XCTAssertEqual(summary.pulled, 3)
        XCTAssertEqual(summary.outcome, .done)
        XCTAssertEqual(try cursor(db), "c3")
        let inbox = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_inbox") }
        XCTAssertEqual(inbox, 3)
        let status = try SyncStatus.read(db)
        XCTAssertEqual(status.unappliedChanges, 3)
        XCTAssertNotNil(status.lastPullOkAt)
    }

    func testNextSyncResumesFromTheSavedCursorAndAnEmptyPageKeepsIt() async throws {
        let db = try queue()
        let api = FakeAPI()
        api.pullRespond = { cursor in
            cursor == nil ? SyncPullResponse(changes: [change("c1", "training_plan")], nextCursor: "c1", hasMore: false)
                          : SyncPullResponse(changes: [], nextCursor: cursor ?? "", hasMore: false)
        }
        let e = engine(db, api)
        _ = await e.syncOnce()
        let second = await e.syncOnce()
        XCTAssertEqual(api.pulls, [nil, "c1"])
        XCTAssertEqual(try cursor(db), "c1")
        XCTAssertEqual(second.pulled, 0)
    }

    /// The device's own pushes come back in the feed: they teach the version and nothing else.
    func testOwnWriteTypesOnlyUpdateTheKnownVersion() async throws {
        let db = try queue()
        let api = FakeAPI()
        let session = UUID()
        api.pullRespond = { cursor in
            cursor == nil ? SyncPullResponse(changes: [change("c1", "workout_session", entity: session, version: 4)], nextCursor: "c1", hasMore: false)
                          : SyncPullResponse(changes: [], nextCursor: cursor ?? "", hasMore: false)
        }
        _ = await engine(db, api).syncOnce()
        let version = try await db.read { try Int.fetchOne($0, sql: "SELECT server_version FROM sync_versions WHERE entity_id = ?", arguments: [DBText.id(session)]) }
        let inbox = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_inbox") }
        XCTAssertEqual(version, 4)
        XCTAssertEqual(inbox, 0)
    }

    /// docs/08 §9 pull replay: the same page twice leaves the same state; an older version never overwrites a newer one.
    func testReplayedAndStalePagesAreIdempotent() async throws {
        let db = try queue()
        let api = FakeAPI()
        let plan = UUID()
        let newer = change("c2", "training_plan", entity: plan, version: 3, payload: .object(["title": .string("new")]))
        let older = change("c1", "training_plan", entity: plan, version: 2, payload: .object(["title": .string("old")]))
        api.pullRespond = { _ in SyncPullResponse(changes: [newer, older, newer], nextCursor: "c2", hasMore: false) }
        let e = engine(db, api)
        _ = await e.syncOnce()
        try await db.write { try $0.execute(sql: "DELETE FROM sync_cursor") }
        _ = await e.syncOnce() // same page again
        let rows: [[String]] = try await db.read { try Row.fetchAll($0, sql: "SELECT server_version, payload_json FROM sync_inbox").map { ["\($0["server_version"] as Int64)", $0["payload_json"] as String] } }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][0], "3")
        XCTAssertTrue(rows[0][1].contains("new"))
    }

    func testDeleteIsKeptAsATombstoneInTheInbox() async throws {
        let db = try queue()
        let api = FakeAPI()
        let plan = UUID()
        api.pullRespond = { _ in SyncPullResponse(changes: [change("c1", "ai_recommendation", entity: plan, version: 5, op: "delete", payload: .object(["id": .string("p"), "deletedAt": .string("2026-11-10T00:00:00.000Z")]))],
                                                  nextCursor: "c1", hasMore: false) }
        _ = await engine(db, api).syncOnce()
        let op = try await db.read { try String.fetchOne($0, sql: "SELECT operation FROM sync_inbox") }
        XCTAssertEqual(op, "delete")
    }

    /// 410: the outbox is untouched, the cursor restarts, and the pull begins again without a cursor (once).
    func testCursorExpiredResetsTheCursorKeepsTheOutboxAndRepulls() async throws {
        let db = try queue()
        try await db.write {
            try $0.execute(sql: "INSERT INTO sync_cursor (scope, cursor, updated_at) VALUES ('main', 'stale', 'x')")
            try $0.execute(sql: "INSERT INTO sync_outbox (mutation_id, entity_type, entity_id, action, base_version, json, created_at, payload_version, state) VALUES ('m', 'set_result', 'e', 'upsert', 0, '{}', 'x', 2, 'rejected')")
        }
        let api = FakeAPI()
        api.pullRespond = { cursor in
            if cursor == "stale" { throw SyncTransportError.cursorExpired }
            return SyncPullResponse(changes: [change("f1", "training_plan")], nextCursor: "f1", hasMore: false)
        }
        let summary = await engine(db, api).syncOnce()
        XCTAssertEqual(api.pulls, ["stale", nil])
        XCTAssertEqual(summary.cursorResets, 1)
        XCTAssertEqual(try cursor(db), "f1")
        let outbox = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") }
        XCTAssertEqual(outbox, 1)
    }

    func testCursorExpiredTwiceStopsInsteadOfLooping() async throws {
        let db = try queue()
        let api = FakeAPI()
        api.pullRespond = { _ in throw SyncTransportError.cursorExpired }
        let summary = await engine(db, api).syncOnce()
        XCTAssertEqual(api.pulls.count, 2)
        XCTAssertEqual(summary.outcome, .serverError(status: 410))
    }

    func testFailedPageApplicationLeavesTheCursorUnmoved() async throws {
        let db = try queue()
        try await db.write { try $0.execute(sql: "INSERT INTO sync_cursor (scope, cursor, updated_at) VALUES ('main', 'c0', 'x')") }
        let api = FakeAPI()
        // version 0 violates `server_version >= 1` in sync_inbox, so the page transaction fails and rolls back.
        api.pullRespond = { _ in SyncPullResponse(changes: [change("c1", "training_plan", version: 2), change("c2", "training_plan", version: 0)], nextCursor: "c2", hasMore: false) }
        let summary = await engine(db, api).syncOnce()
        XCTAssertEqual(summary.outcome, .offline, "a local failure is not reported as success")
        XCTAssertEqual(try cursor(db), "c0")
        let inbox = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_inbox") }
        XCTAssertEqual(inbox, 0, "the first change of the page was rolled back too")
    }

    func testPullOnlyAfterPushSucceeded() async throws {
        let db = try queue()
        let api = FakeAPI()
        api.respond = { _ in throw SyncTransportError.offline }
        try await db.write {
            try $0.execute(sql: "INSERT INTO sync_outbox (mutation_id, entity_type, entity_id, action, base_version, json, created_at, payload_version) VALUES ('a0000000-0000-0000-0000-000000000001', 'set_result', 'a0000000-0000-0000-0000-000000000002', 'upsert', 0, '{\"mutationId\":\"a0000000-0000-0000-0000-000000000001\",\"entityId\":\"a0000000-0000-0000-0000-000000000002\",\"action\":\"upsert\",\"clientChangedAt\":\"2026-11-10T00:00:00.000Z\",\"payload\":{}}', 'x', 2)")
        }
        let summary = await engine(db, api).syncOnce()
        XCTAssertEqual(summary.outcome, .offline)
        XCTAssertTrue(api.pulls.isEmpty)
    }

    func testPullUnauthorizedAsksForSignIn() async throws {
        let db = try queue()
        let api = FakeAPI()
        api.pullRespond = { _ in throw SyncTransportError.unauthorized }
        let summary = await engine(db, api).syncOnce()
        XCTAssertEqual(summary.outcome, .needsSignIn)
    }
}
