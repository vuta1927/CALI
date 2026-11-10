import CaliDomain
import Foundation
import GRDB

/// Stable id of this install for `POST /v1/sync/push` (ADR-033). Kept in `sync_state`; replaced only when the
/// server says another user owns it.
public struct SyncDeviceIdentity: Sendable {
    let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }
    public init(coordinator: WorkoutCoordinator) { writer = coordinator.writer }

    public func current() async throws -> UUID {
        try await writer.write { db in
            if let text = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'device_id'"), let id = UUID(uuidString: text) { return id }
            let id = UUID()
            try db.execute(sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('device_id', ?)", arguments: [DBText.id(id)])
            return id
        }
    }

    @discardableResult
    public func regenerate() async throws -> UUID {
        let id = UUID()
        try await writer.write { try $0.execute(sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('device_id', ?)", arguments: [DBText.id(id)]) }
        return id
    }
}

/// Retry delay after a failed attempt: 5 s doubling to a 1 h cap, with jitter (docs/08 §8).
public enum SyncBackoff {
    public static let base: TimeInterval = 5
    public static let cap: TimeInterval = 3_600

    /// `attempt` is the number of attempts made so far (1 after the first failure). `jitter` is a factor near 1.
    public static func delay(afterAttempt attempt: Int, jitter: Double) -> TimeInterval {
        let raw = base * pow(2, Double(max(attempt, 1) - 1))
        return min(cap, raw * jitter)
    }
}

public struct SyncRunSummary: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case done
        case nothingToSend
        case offline
        case needsSignIn
        case rateLimited(until: Date)
        case serverError(status: Int)
        case deviceIdReplaced
    }

    public var outcome: Outcome
    public var sent = 0
    public var acked = 0
    public var retryLater = 0
    public var conflicted = 0
    public var rejected = 0
    /// Changes received from the server (pull) and how often the cursor had to be reset.
    public var pulled = 0
    /// Pulled changes written into the local content tables.
    public var applied = 0
    public var cursorResets = 0
}

/// Sends the local outbox (docs/08 §3, §8): `pending → sending → acked | conflicted | rejected | pending(next attempt)`.
///
/// - Rows of one entity go one at a time; a later row is rebased onto the server version the earlier one reached,
///   before its first attempt only. After an attempt the mutation is never changed (same `mutationId`, same
///   `baseVersion`, same payload).
/// - A network failure, 5xx, 429 or `dependency_missing` keeps the row pending with a backoff. `version_conflict` waits for
///   the user (conflict inbox). Any other rejection is final and shown.
/// - A batch the server refuses as a whole (400/413) is split down to single mutations to isolate the bad one.
/// - Rows left `sending` by a crash go back to `pending`: the server answers `duplicate` for what it already has.
public actor OutboxSyncEngine {
    private let writer: any DatabaseWriter
    private let api: any SyncAPI
    private let device: SyncDeviceIdentity
    private let clock: @Sendable () -> Date
    private let jitter: @Sendable () -> Double
    private let batchSize: Int

    public init(
        writer: any DatabaseWriter, api: any SyncAPI, clock: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) }, batchSize: Int = 100
    ) {
        self.writer = writer
        self.api = api
        device = SyncDeviceIdentity(writer: writer)
        self.clock = clock
        self.jitter = jitter
        self.batchSize = min(max(batchSize, 1), 100)
    }

    private struct Claimed {
        var seq: Int64
        var attempts: Int
        var mutation: SyncMutation
    }

    /// Sends everything that is due, batch after batch, until nothing is due or a run-level problem stops it.
    public func syncOnce() async -> SyncRunSummary {
        var summary = SyncRunSummary(outcome: .nothingToSend)
        do {
            let now = clock()
            try await writer.write { db in
                try db.execute(sql: "UPDATE sync_outbox SET state = 'pending' WHERE state = 'sending'")
                try ContentOutbox.enqueueDirty(db, now: now)
            }
            while true {
                let batch = try await claim()
                if batch.isEmpty { break }
                let outcome = try await send(batch, into: &summary)
                if let outcome { summary.outcome = outcome; return summary }
                summary.outcome = .done
            }
            if let stop = try await pull(into: &summary) { summary.outcome = stop; return summary }
            if summary.pulled > 0, summary.outcome == .nothingToSend { summary.outcome = .done }
        } catch {
            summary.outcome = .offline
        }
        return summary
    }

    // MARK: Claim

    private func claim() async throws -> [Claimed] {
        let now = clock()
        return try await writer.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT o.* FROM sync_outbox o
                WHERE o.state = 'pending' AND o.payload_version = 2 AND (o.next_attempt_at IS NULL OR o.next_attempt_at <= ?)
                  AND NOT EXISTS (
                      SELECT 1 FROM sync_outbox p
                      WHERE p.entity_type = o.entity_type AND p.entity_id = o.entity_id AND p.seq < o.seq
                        AND p.state IN ('pending', 'sending', 'conflicted'))
                ORDER BY o.seq LIMIT ?
                """, arguments: [DBText.time(now), batchSize])
            return try rows.map { row in
                let seq: Int64 = row["seq"]
                let attempts: Int = row["attempts"]
                let envelope = try SyncWireCoding.decoder().decode(StoredEnvelope.self, from: Data((row["json"] as String).utf8))
                let entityType: String = row["entity_type"]
                let entityId: UUID = UUID(uuidString: row["entity_id"]) ?? envelope.entityId
                // Rebase before the first attempt only; afterwards the stored base is used unchanged.
                var base: Int = row["base_version"] ?? 0
                if attempts == 0 {
                    let known = try Int.fetchOne(db, sql: "SELECT server_version FROM sync_versions WHERE entity_type = ? AND entity_id = ?",
                                                 arguments: [entityType, DBText.id(entityId)])
                    base = known ?? base
                }
                try db.execute(sql: "UPDATE sync_outbox SET state = 'sending', attempts = attempts + 1, last_attempt_at = ?, base_version = ? WHERE seq = ?",
                               arguments: [DBText.time(now), base, seq])
                let mutation = SyncMutation(mutationId: envelope.mutationId, entityType: entityType, entityId: entityId, action: envelope.action,
                                            baseVersion: base, clientChangedAt: envelope.clientChangedAt, payload: envelope.payload)
                return Claimed(seq: seq, attempts: attempts + 1, mutation: mutation)
            }
        }
    }

    private struct StoredEnvelope: Decodable {
        var mutationId: UUID
        var entityId: UUID
        var action: String
        var clientChangedAt: Date
        var payload: JSONValue
    }

    // MARK: Send

    /// Returns a run-level outcome when the run must stop, nil to continue with the next batch.
    private func send(_ batch: [Claimed], into summary: inout SyncRunSummary) async throws -> SyncRunSummary.Outcome? {
        summary.sent += batch.count
        let deviceId = try await device.current()
        do {
            let response = try await api.push(SyncPushRequest(deviceId: deviceId, mutations: batch.map(\.mutation)))
            try await apply(response, to: batch, into: &summary)
            return nil
        } catch let error as SyncTransportError {
            switch error {
            case .offline:
                try await release(batch, attemptCounts: true, retryAfter: nil)
                return .offline
            case .server(let status):
                try await release(batch, attemptCounts: true, retryAfter: nil)
                return .serverError(status: status)
            case .rateLimited(let retryAfter):
                let until = clock().addingTimeInterval(retryAfter ?? SyncBackoff.delay(afterAttempt: batch.map(\.attempts).max() ?? 1, jitter: jitter()))
                try await release(batch, attemptCounts: true, retryAfter: until)
                return .rateLimited(until: until)
            case .unauthorized:
                try await release(batch, attemptCounts: false, retryAfter: nil) // not the mutation's fault: no attempt spent
                return .needsSignIn
            case .deviceOwnerMismatch:
                try await release(batch, attemptCounts: false, retryAfter: nil)
                try await device.regenerate()
                return .deviceIdReplaced
            case .cursorExpired:
                try await release(batch, attemptCounts: true, retryAfter: nil)
                return .serverError(status: 410) // a push never answers 410; treated as a server fault
            case .batchRefused(let status, let code):
                if batch.count > 1 {
                    // Isolate the bad mutation: single sends, each refused one is rejected on its own.
                    try await release(batch, attemptCounts: false, retryAfter: nil)
                    for one in try await claimSpecific(batch.map(\.seq)) {
                        if let stop = try await send([one], into: &summary) { return stop }
                    }
                    return nil
                }
                try await mark(batch[0], state: "rejected", code: code ?? "batch_refused_\(status)", message: "Máy chủ từ chối yêu cầu (HTTP \(status)).")
                summary.rejected += 1
                return nil
            }
        }
    }

    private func claimSpecific(_ seqs: [Int64]) async throws -> [Claimed] {
        // Re-read exactly these rows as claimed; used after a whole-batch refusal.
        let now = clock()
        return try await writer.write { db in
            try seqs.compactMap { seq in
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_outbox WHERE seq = ? AND state = 'pending'", arguments: [seq]) else { return nil }
                let envelope = try SyncWireCoding.decoder().decode(StoredEnvelope.self, from: Data((row["json"] as String).utf8))
                let base: Int = row["base_version"] ?? 0
                let attempts: Int = row["attempts"]
                try db.execute(sql: "UPDATE sync_outbox SET state = 'sending', attempts = attempts + 1, last_attempt_at = ? WHERE seq = ?", arguments: [DBText.time(now), seq])
                let entityType: String = row["entity_type"]
                return Claimed(seq: seq, attempts: attempts + 1,
                               mutation: SyncMutation(mutationId: envelope.mutationId, entityType: entityType, entityId: envelope.entityId, action: envelope.action,
                                                      baseVersion: base, clientChangedAt: envelope.clientChangedAt, payload: envelope.payload))
            }
        }
    }

    /// Puts claimed rows back to `pending`. A spent attempt schedules the next one with backoff.
    private func release(_ batch: [Claimed], attemptCounts: Bool, retryAfter: Date?) async throws {
        let now = clock()
        try await writer.write { db in
            for item in batch {
                let next: Date? = attemptCounts ? (retryAfter ?? now.addingTimeInterval(SyncBackoff.delay(afterAttempt: item.attempts, jitter: jitter()))) : nil
                try db.execute(sql: "UPDATE sync_outbox SET state = 'pending', attempts = ?, next_attempt_at = ? WHERE seq = ?",
                               arguments: [attemptCounts ? item.attempts : item.attempts - 1, next.map(DBText.time), item.seq])
            }
        }
    }

    private func mark(_ item: Claimed, state: String, code: String, message: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE sync_outbox SET state = ?, error_code = ?, last_error = ? WHERE seq = ?",
                           arguments: [state, code, String(LogRedactor.redact(message).prefix(300)), item.seq])
        }
    }

    // MARK: Pull (docs/08 §7)

    /// Changes of these types are written by this device only (MVP: one device per account), so the local row stays
    /// authoritative and the change only teaches us the server version. Everything else waits in `sync_inbox`.
    static let ownWriteTypes: Set<String> = ["workout_session", "exercise_execution", "set_result"]
    static let mainScope = "main"

    private func pull(into summary: inout SyncRunSummary) async throws -> SyncRunSummary.Outcome? {
        var resetOnce = false
        var pages = 0
        while pages < 1_000 {
            let cursor = try await writer.read { try String.fetchOne($0, sql: "SELECT cursor FROM sync_cursor WHERE scope = ?", arguments: [Self.mainScope]) }
            let page: SyncPullResponse
            do {
                page = try await api.pull(cursor: cursor, limit: 100)
            } catch SyncTransportError.cursorExpired where !resetOnce {
                // The outbox stays; only the read position restarts. The first page of a full pull repeats what we hold: upserts.
                resetOnce = true
                summary.cursorResets += 1
                try await writer.write { try $0.execute(sql: "DELETE FROM sync_cursor WHERE scope = ?", arguments: [Self.mainScope]) }
                continue
            } catch let error as SyncTransportError {
                return runOutcome(for: error)
            }
            summary.applied += try await apply(page)
            summary.pulled += page.changes.count
            pages += 1
            if !page.hasMore {
                // Rows that waited for an edit of ours to be settled may be applicable now.
                summary.applied += try await writer.write { [now = clock()] in try ContentApplier.applyInbox($0, now: now) }
                return nil
            }
            if page.changes.isEmpty, page.nextCursor == cursor { return nil } // no progress: stop instead of looping
        }
        return nil
    }

    private func runOutcome(for error: SyncTransportError) -> SyncRunSummary.Outcome {
        switch error {
        case .offline: .offline
        case .unauthorized: .needsSignIn
        case .rateLimited(let retryAfter): .rateLimited(until: clock().addingTimeInterval(retryAfter ?? 60))
        case .server(let status), .batchRefused(let status, _): .serverError(status: status)
        case .deviceOwnerMismatch: .serverError(status: 409)
        case .cursorExpired: .serverError(status: 410)
        }
    }

    /// One transaction: every change of the page, then the cursor. Applying twice is harmless (upserts keep the highest version).
    private func apply(_ page: SyncPullResponse) async throws -> Int {
        let now = clock()
        return try await writer.write { db -> Int in
            for change in page.changes {
                try db.execute(sql: """
                    INSERT INTO sync_versions (entity_type, entity_id, server_version) VALUES (?, ?, ?)
                    ON CONFLICT(entity_type, entity_id) DO UPDATE SET server_version = MAX(server_version, excluded.server_version)
                    """, arguments: [change.entityType, DBText.id(change.entityId), change.serverVersion])
                guard !Self.ownWriteTypes.contains(change.entityType) else { continue }
                try db.execute(sql: """
                    INSERT INTO sync_inbox (entity_type, entity_id, operation, server_version, change_id, payload_json, received_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(entity_type, entity_id) DO UPDATE SET
                        operation = excluded.operation, server_version = excluded.server_version, change_id = excluded.change_id,
                        payload_json = excluded.payload_json, received_at = excluded.received_at
                    WHERE excluded.server_version >= sync_inbox.server_version
                    """, arguments: [change.entityType, DBText.id(change.entityId), change.operation, change.serverVersion, change.changeId,
                                     String(decoding: try SyncWireCoding.encoder().encode(change.payload), as: UTF8.self), DBText.time(now)])
            }
            if !page.nextCursor.isEmpty {
                try db.execute(sql: """
                    INSERT INTO sync_cursor (scope, cursor, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(scope) DO UPDATE SET cursor = excluded.cursor, updated_at = excluded.updated_at
                    """, arguments: [Self.mainScope, page.nextCursor, DBText.time(now)])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('last_pull_ok_at', ?)", arguments: [DBText.time(now)])
            return try ContentApplier.applyInbox(db, now: now)
        }
    }

    // MARK: Receipts

    private func apply(_ response: SyncPushResponse, to batch: [Claimed], into summary: inout SyncRunSummary) async throws {
        let now = clock()
        let byId = Dictionary(response.results.map { ($0.mutationId, $0) }, uniquingKeysWith: { first, _ in first })
        let jitterFactor = jitter
        let counts = try await writer.write { db -> SyncRunSummary in
            var local = SyncRunSummary(outcome: .done)
            for item in batch {
                guard let result = byId[item.mutation.mutationId] else {
                    // No answer for this mutation: keep it, try again later.
                    try db.execute(sql: "UPDATE sync_outbox SET state = 'pending', next_attempt_at = ? WHERE seq = ?",
                                   arguments: [DBText.time(now.addingTimeInterval(SyncBackoff.delay(afterAttempt: item.attempts, jitter: jitterFactor()))), item.seq])
                    local.retryLater += 1
                    continue
                }
                switch result.status {
                case .applied, .duplicate:
                    try db.execute(sql: "UPDATE sync_outbox SET state = 'acked', server_version = ?, error_code = NULL, last_error = NULL, next_attempt_at = NULL WHERE seq = ?",
                                   arguments: [result.serverVersion, item.seq])
                    try ContentOutbox.acknowledge(db, type: item.mutation.entityType, id: item.mutation.entityId, action: item.mutation.action, payload: item.mutation.payload)
                    if let version = result.serverVersion {
                        try db.execute(sql: """
                            INSERT INTO sync_versions (entity_type, entity_id, server_version) VALUES (?, ?, ?)
                            ON CONFLICT(entity_type, entity_id) DO UPDATE SET server_version = MAX(server_version, excluded.server_version)
                            """, arguments: [item.mutation.entityType, DBText.id(item.mutation.entityId), version])
                    }
                    local.acked += 1
                case .conflict where result.error?.retryable == true:
                    let next = now.addingTimeInterval(SyncBackoff.delay(afterAttempt: item.attempts, jitter: jitterFactor()))
                    try db.execute(sql: "UPDATE sync_outbox SET state = 'pending', error_code = ?, last_error = ?, next_attempt_at = ? WHERE seq = ?",
                                   arguments: [result.error?.code, Self.text(result.error), DBText.time(next), item.seq])
                    local.retryLater += 1
                case .conflict:
                    let entity = try result.serverEntity.map { String(decoding: try SyncWireCoding.encoder().encode($0), as: UTF8.self) }
                    try db.execute(sql: "UPDATE sync_outbox SET state = 'conflicted', error_code = ?, last_error = ?, server_version = ?, server_entity_json = ? WHERE seq = ?",
                                   arguments: [result.error?.code ?? "version_conflict", Self.text(result.error), result.serverVersion, entity, item.seq])
                    local.conflicted += 1
                case .rejected:
                    try db.execute(sql: "UPDATE sync_outbox SET state = 'rejected', error_code = ?, last_error = ? WHERE seq = ?",
                                   arguments: [result.error?.code ?? "rejected", Self.text(result.error), item.seq])
                    local.rejected += 1
                }
            }
            try db.execute(sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('last_push_ok_at', ?)", arguments: [DBText.time(now)])
            return local
        }
        summary.acked += counts.acked
        summary.retryLater += counts.retryLater
        summary.conflicted += counts.conflicted
        summary.rejected += counts.rejected
    }

    /// Server text, redacted and cut. `details` can name a field but never carries values the UI should show.
    private static func text(_ error: MutationError?) -> String? {
        error.map { String(LogRedactor.redact($0.message).prefix(300)) }
    }
}
