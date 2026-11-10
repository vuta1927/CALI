import CaliDomain
import Foundation
import GRDB

/// What the app tells the user about sync (docs/08 §8): waiting, needs attention, or in step with the server.
public struct SyncStatus: Equatable, Sendable {
    public enum Badge: Equatable, Sendable { case synced, waiting, needsAttention }

    public var pending: Int
    public var conflicted: Int
    public var rejected: Int
    public var oldestPendingAt: Date?
    public var lastPushOkAt: Date?
    public var lastPullOkAt: Date?
    /// Pulled changes that no local applier has consumed yet (content slice).
    public var unappliedChanges: Int

    public init(pending: Int, conflicted: Int, rejected: Int, oldestPendingAt: Date? = nil, lastPushOkAt: Date? = nil, lastPullOkAt: Date? = nil, unappliedChanges: Int = 0) {
        self.lastPullOkAt = lastPullOkAt
        self.unappliedChanges = unappliedChanges
        self.pending = pending
        self.conflicted = conflicted
        self.rejected = rejected
        self.oldestPendingAt = oldestPendingAt
        self.lastPushOkAt = lastPushOkAt
    }

    public var badge: Badge {
        if conflicted + rejected > 0 { return .needsAttention }
        return pending > 0 ? .waiting : .synced
    }

    public static func read(_ reader: any DatabaseReader) throws -> SyncStatus {
        try reader.read { db in
            func count(_ state: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox WHERE state = ? AND payload_version = 2", arguments: [state]) ?? 0
            }
            return SyncStatus(
                pending: try count("pending") + count("sending"), conflicted: try count("conflicted"), rejected: try count("rejected"),
                oldestPendingAt: try String.fetchOne(db, sql: "SELECT MIN(created_at) FROM sync_outbox WHERE state IN ('pending', 'sending') AND payload_version = 2")
                    .flatMap(DBText.date),
                lastPushOkAt: try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'last_push_ok_at'").flatMap(DBText.date),
                lastPullOkAt: try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'last_pull_ok_at'").flatMap(DBText.date),
                unappliedChanges: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_inbox") ?? 0
            )
        }
    }
}

/// One mutation the user has to look at (conflict inbox, docs/08 §5). Shows the entity kind and the server's
/// reason only: no payload, so nothing sensitive (body weight) is read out of the outbox.
public struct SyncIssue: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case conflicted, rejected }

    public var id: Int64
    public var kind: Kind
    public var entityType: String
    public var entityId: UUID
    public var code: String
    public var message: String
    public var serverVersion: Int64?

    /// A conflict on a content entity can take the server's version; sessions and sets only keep the local one.
    public var canUseServer: Bool { kind == .conflicted && SyncConflictResolver.canUseServer(entityType: entityType) }

    public static func read(_ reader: any DatabaseReader) throws -> [SyncIssue] {
        try reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sync_outbox WHERE state IN ('conflicted', 'rejected') AND payload_version = 2 ORDER BY seq").compactMap { row in
                guard let entityId = UUID(uuidString: row["entity_id"]), let kind = Kind(rawValue: row["state"]) else { return nil }
                return SyncIssue(id: row["seq"], kind: kind, entityType: row["entity_type"], entityId: entityId,
                                 code: row["error_code"] ?? "unknown", message: row["last_error"] ?? "", serverVersion: row["server_version"])
            }
        }
    }
}
