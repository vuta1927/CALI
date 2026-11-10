import CaliDomain
import GRDB
import XCTest
@testable import CaliCore

/// IOS-007 slice 1: docs/08 §3, §8 and the §9 test vectors for the push side, against a fake `SyncAPI`.
private func result(_ m: SyncMutation, _ status: SyncMutationResult.Status = .applied, version: Int64? = 1, error: MutationError? = nil, entity: JSONValue? = nil) -> SyncMutationResult {
    SyncMutationResult(mutationId: m.mutationId, status: status, serverVersion: version, serverEntity: entity, error: error)
}

private func applied(_ request: SyncPushRequest) -> SyncPushResponse {
    SyncPushResponse(results: request.mutations.map { result($0) })
}


final class OutboxSyncEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Scripted server: records every request and answers with `respond`.
    final class FakeAPI: SyncAPI, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [SyncPushRequest] = []
        var respond: @Sendable (SyncPushRequest) throws -> SyncPushResponse = { _ in SyncPushResponse(results: []) }
        var requests: [SyncPushRequest] { lock.withLock { _requests } }
        var pullRespond: @Sendable (String?) throws -> SyncPullResponse = { cursor in SyncPullResponse(changes: [], nextCursor: cursor ?? "", hasMore: false) }
        private var _pulls: [String?] = []
        var pulls: [String?] { lock.withLock { _pulls } }
        func pull(cursor: String?, limit: Int) async throws -> SyncPullResponse {
            lock.withLock { _pulls.append(cursor) }
            return try pullRespond(cursor)
        }
        func push(_ request: SyncPushRequest) async throws -> SyncPushResponse {
            lock.withLock { _requests.append(request) }
            return try respond(request)
        }
    }

    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func makeEngine(_ db: DatabaseQueue, _ api: FakeAPI, _ clock: Clock, batch: Int = 100) -> OutboxSyncEngine {
        OutboxSyncEngine(writer: db, api: api, clock: { clock.now }, jitter: { 1 }, batchSize: batch)
    }

    @discardableResult
    private func seed(_ db: DatabaseQueue, _ type: String, id: UUID = UUID(), base: Int? = 0, at: Date? = nil, payload: String = #"{"id":"x"}"#) throws -> UUID {
        let mutationId = UUID()
        let envelope = #"{"mutationId":"\#(DBText.id(mutationId))","entityType":"\#(type)","entityId":"\#(DBText.id(id))","action":"upsert","clientChangedAt":"2026-11-10T00:00:00.000Z","payload":\#(payload)}"#
        try db.write {
            try $0.execute(sql: "INSERT INTO sync_outbox (mutation_id, entity_type, entity_id, action, base_version, json, created_at, payload_version) VALUES (?, ?, ?, 'upsert', ?, ?, ?, 2)",
                           arguments: [DBText.id(mutationId), type, DBText.id(id), base, envelope, DBText.time(at ?? t0)])
        }
        return mutationId
    }

    private func states(_ db: DatabaseQueue) throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT state FROM sync_outbox ORDER BY seq") }
    }

    func testAppliedMutationsAreAckedAndTheServerVersionIsRemembered() async throws {
        let db = try CaliDatabase.openInMemory() as! DatabaseQueue
        let api = FakeAPI()
        api.respond = { applied($0) }
        let id = UUID()
        try seed(db, "workout_session", id: id)
        let summary = await makeEngine(db, api, Clock(t0)).syncOnce()
        XCTAssertEqual(summary.outcome, .done)
        XCTAssertEqual(summary.acked, 1)
        XCTAssertEqual(try states(db), ["acked"])
        let known = try await db.read { try Int.fetchOne($0, sql: "SELECT server_version FROM sync_versions WHERE entity_id = ?", arguments: [DBText.id(id)]) }
        XCTAssertEqual(known, 1)
        XCTAssertNotNil(try SyncStatus.read(db).lastPushOkAt)
        XCTAssertEqual(try SyncStatus.read(db).badge, .synced)
    }

    func testNothingDueMeansNoRequest() async throws {
        let db = try CaliDatabase.openInMemory() as! DatabaseQueue
        let api = FakeAPI()
        let summary = await makeEngine(db, api, Clock(t0)).syncOnce()
        XCTAssertEqual(summary.outcome, .nothingToSend)
        XCTAssertTrue(api.requests.isEmpty)
    }

    /// Offline: the same mutation (id, base, payload) goes again after the backoff, never earlier.
    func testOfflineKeepsTheRowAndResendsTheSameMutationAfterTheBackoff() async throws {
        let db = try CaliDatabase.openInMemory() as! DatabaseQueue
        let api = FakeAPI()
        api.respond = { _ in throw SyncTransportError.offline }
        let mutationId = try seed(db, "set_result")
        let clock = Clock(t0)
        let engine = makeEngine(db, api, clock)
        let first = await engine.syncOnce()
        XCTAssertEqual(first.outcome, .offline)
        XCTAssertEqual(try states(db), ["pending"])
        XCTAssertEqual(try SyncStatus.read(db).badge, .waiting)

        clock.now = t0.addingTimeInterval(2)
        _ = await engine.syncOnce()
        XCTAssertEqual(api.requests.count, 1, "still inside the 5 s backoff")

        api.respond = { applied($0) }
        clock.now = t0.addingTimeInterval(6)
        _ = await engine.syncOnce()
        XCTAssertEqual(api.requests.count, 2)
        XCTAssertEqual(api.requests[1].mutations, api.requests[0].mutations, "same id, base version and payload on every attempt")
        XCTAssertEqual(api.requests[1].mutations[0].mutationId, mutationId)
        XCTAssertEqual(try states(db), ["acked"])
    }

    func testBackoffDoublesAndStopsAtOneHour() {
        XCTAssertEqual(SyncBackoff.delay(afterAttempt: 1, jitter: 1), 5)
        XCTAssertEqual(SyncBackoff.delay(afterAttempt: 2, jitter: 1), 10)
        XCTAssertEqual(SyncBackoff.delay(afterAttempt: 6, jitter: 1), 160)
        XCTAssertEqual(SyncBackoff.delay(afterAttempt: 30, jitter: 1.2), 3_600, "capped")
    }

    func testRowLeftSendingByACrashIsSentAgain() async throws {
        let db = try CaliDatabase.openInMemory() as! DatabaseQueue
        let api = FakeAPI()
        api.respond = { applied($0) }
        try seed(db, "set_result")
        try await db.write { try $0.execute(sql: "UPDATE sync_outbox SET state = 'sending', attempts = 1") }
        _ = await makeEngine(db, api, Clock(t0)).syncOnce()
        XCTAssertEqual(try states(db), ["acked"])
    }

    func testDuplicateReceiptCountsAsAcked() async throws {
        let db = try CaliDatabase.openInMemory() as! DatabaseQueue
        let api = FakeAPI()
        api.respond = { r in SyncPushResponse(results: r.mutations.map { result($0, .duplicate, version: 3) }) }
        try seed(db, "set_result")
        let summary = await makeEngine(db, api, Clock(t0)).syncOnce()
        XCTAssertEqual(summary.acked, 1)
        XCTAssertEqual(try states(db), ["acked"])
    }

    func testDependencyMissingIsRetriedLaterWithTheSameMutationId() async throws {
        let db = try CaliDatabase.openInMemory() as! DatabaseQueue
        let api = FakeAPI()
        api.respond = { r in SyncPushResponse(results: r.mutations.map {
            result($0, .conflict, version: nil, error: MutationError(code: "dependency_missing", message: "parent missing", retryable: true))
        }) }
        let mutationId = try seed(db, "exercise_execution")
        let clock = Clock(t0)
        let engine = makeEngine(db, api, clock)
        let first = await engine.syncOnce()
        XCTAssertEqual(first.retryLater, 1)
        XCTAssertEqual(try states(db), ["pending"])
        api.respond = { applied($0) }
        clock.now = t0.addingTimeInterval(10)
        _ = await engine.syncOnce()
        XCTAssertEqual(api.requests.last?.mutations[0].mutationId, mutationId)
        XCTAssertEqual(try states(db), ["acked"])
    }

    func testVersionConflictWaitsForTheUserAndBlocksLaterRowsOfThatEntity() async throws {
        let db = try CaliDatabase.openInMemory() as! DatabaseQueue
        let api = FakeAPI()
        let entity = UUID()
        api.respond = { r in SyncPushResponse(results: r.mutations.map {
            result($0, .conflict, version: 4, error: MutationError(code: "version_conflict", message: "changed elsewhere", retryable: false), entity: .object(["id": .string("s")]))
        }) }
        try seed(db, "set_result", id: entity, base: 2)
        try seed(db, "set_result", id: entity, base: nil)
        let engine = makeEngine(db, api, Clock(t0))
        let summary = await engine.syncOnce()
        XCTAssertEqual(summary.conflicted, 1)
        XCTAssertEqual(try states(db), ["conflicted", "pending"])
        _ = await engine.syncOnce()
        XCTAssertEqual(api.requests.count, 1, "the second row of the entity is not sent while the first is unresolved")
        let issues = try SyncIssue.read(db)
        XCTAssertEqual(issues.map(\.kind), [.conflicted])
        XCTAssertEqual(issues.first?.code, "version_conflict")
        XCTAssertEqual(issues.first?.serverVersion, 4)
        XCTAssertEqual(try SyncStatus.read(db).badge, .needsAttention)
        let snapshot = try await db.read { try String.fetchOne($0, sql: "SELECT server_entity_json FROM sync_outbox WHERE state = 'conflicted'") }
        XCTAssertNotNil(snapshot)
    }

    func testRejectedIsFinalAndShowsTheServerReasonRedacted() async throws {
        let db = try CaliDatabase.openInMemory() as! DatabaseQueue
        let api = FakeAPI()
        api.respond = { r in SyncPushResponse(results: r.mutations.map {
            result($0, .rejected, version: nil, error: MutationError(code: "validation_failed", message: "bad value token=abc123 on field value", retryable: false))
        }) }
        try seed(db, "body_measurement")
        let engine = makeEngine(db, api, Clock(t0))
        _ = await engine.syncOnce()
        _ = await engine.syncOnce()
        XCTAssertEqual(api.requests.count, 1, "never resent")
        let issue = try XCTUnwrap(try SyncIssue.read(db).first)
        XCTAssertEqual([issue.kind, .rejected], [.rejected, .rejected])
        XCTAssertFalse(issue.message.contains("abc123"))
    }

    /// docs/08 §3: #2 of the same entity waits for #1 and then carries the version #1 reached.
    func testSecondMutationOfAnEntityIsRebasedOntoTheAckedVersion() async throws {
        let db = try CaliCore_openQueue()
        let api = FakeAPI()
        api.respond = { r in SyncPushResponse(results: r.mutations.map { SyncMutationResult(mutationId: $0.mutationId, status: .applied, serverVersion: Int64($0.baseVersion + 1)) }) }
        let entity = UUID()
        try seed(db, "workout_session", id: entity, base: 0)
        try seed(db, "workout_session", id: entity, base: nil)
        let engine = makeEngine(db, api, Clock(t0))
        _ = await engine.syncOnce()
        XCTAssertEqual(api.requests.map { $0.mutations.map(\.baseVersion) }, [[0], [1]], "two requests: first creates (base 0), then the terminal change on version 1")
        XCTAssertEqual(try states(db), ["acked", "acked"])
    }

    func testUnauthorizedStopsTheRunWithoutSpendingAnAttempt() async throws {
        let db = try CaliCore_openQueue()
        let api = FakeAPI()
        api.respond = { _ in throw SyncTransportError.unauthorized }
        try seed(db, "set_result")
        let summary = await makeEngine(db, api, Clock(t0)).syncOnce()
        XCTAssertEqual(summary.outcome, .needsSignIn)
        let attempts = try await db.read { try Int.fetchOne($0, sql: "SELECT attempts FROM sync_outbox") }
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(try states(db), ["pending"])
    }

    func testRateLimitHonoursRetryAfter() async throws {
        let db = try CaliCore_openQueue()
        let api = FakeAPI()
        api.respond = { _ in throw SyncTransportError.rateLimited(retryAfter: 120) }
        try seed(db, "set_result")
        let clock = Clock(t0)
        let engine = makeEngine(db, api, clock)
        let summary = await engine.syncOnce()
        XCTAssertEqual(summary.outcome, .rateLimited(until: t0.addingTimeInterval(120)))
        clock.now = t0.addingTimeInterval(60)
        _ = await engine.syncOnce()
        XCTAssertEqual(api.requests.count, 1)
        api.respond = { applied($0) }
        clock.now = t0.addingTimeInterval(121)
        _ = await engine.syncOnce()
        XCTAssertEqual(try states(db), ["acked"])
    }

    func testAWholeBatchRefusalIsSplitToIsolateTheBadMutation() async throws {
        let db = try CaliCore_openQueue()
        let api = FakeAPI()
        let bad = try seed(db, "set_result", payload: #"{"id":"bad"}"#)
        try seed(db, "set_result")
        try seed(db, "set_result")
        api.respond = { r in
            if r.mutations.count > 1 || r.mutations[0].mutationId == bad { throw SyncTransportError.batchRefused(status: 400, code: "validation_failed") }
            return applied(r)
        }
        let summary = await makeEngine(db, api, Clock(t0)).syncOnce()
        XCTAssertEqual(summary.rejected, 1)
        XCTAssertEqual(summary.acked, 2)
        XCTAssertEqual(Set(try states(db)), ["acked", "rejected"])
        XCTAssertEqual(try SyncIssue.read(db).first?.code, "validation_failed")
    }

    func testDeviceOwnerMismatchGivesANewDeviceIdAndAppliesNothing() async throws {
        let db = try CaliCore_openQueue()
        let api = FakeAPI()
        api.respond = { _ in throw SyncTransportError.deviceOwnerMismatch }
        try seed(db, "set_result")
        let before = try await SyncDeviceIdentity(writer: db).current()
        let summary = await makeEngine(db, api, Clock(t0)).syncOnce()
        XCTAssertEqual(summary.outcome, .deviceIdReplaced)
        let after = try await SyncDeviceIdentity(writer: db).current()
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(try states(db), ["pending"])
    }

    func testBatchesAreCappedAtOneHundredMutations() async throws {
        let db = try CaliCore_openQueue()
        let api = FakeAPI()
        api.respond = { applied($0) }
        for _ in 0..<250 { try seed(db, "set_result") }
        _ = await makeEngine(db, api, Clock(t0)).syncOnce()
        XCTAssertEqual(api.requests.map(\.mutations.count), [100, 100, 50])
        XCTAssertEqual(Set(try states(db)), ["acked"])
    }

    func testRequestUsesOneStableDeviceId() async throws {
        let db = try CaliCore_openQueue()
        let api = FakeAPI()
        api.respond = { applied($0) }
        try seed(db, "set_result")
        let engine = makeEngine(db, api, Clock(t0))
        _ = await engine.syncOnce()
        try seed(db, "set_result")
        _ = await engine.syncOnce()
        XCTAssertEqual(Set(api.requests.map(\.deviceId)).count, 1)
    }

    private func CaliCore_openQueue() throws -> DatabaseQueue { try CaliDatabase.openInMemory() as! DatabaseQueue }
}
