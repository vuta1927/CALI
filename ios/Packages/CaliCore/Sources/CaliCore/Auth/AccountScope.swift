import CaliDomain
import Foundation
import GRDB

/// Which account the data on this device belongs to, and what happens to local data at sign-in and sign-out
/// (docs/08 §6). Data of one account is never pushed to another.
///
/// - First sign-in on a device with no account bound: the user chooses to attach the data already here (it is pushed with its own
///   ids, nothing merged by title or date) or to keep it on the device only.
/// - Same account again: sync resumes.
/// - A different account while the first one's data is still here: refused until that data is deleted.
public struct AccountScope: Sendable {
    let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }
    public init(coordinator: WorkoutCoordinator) { writer = coordinator.writer }

    public enum Check: Equatable, Sendable {
        /// No account bound yet: ask whether to attach the data on this device.
        case attachChoiceNeeded
        case ready
        /// The data here belongs to another account: sign out of it and delete the local data first.
        case otherAccountOnDevice
    }

    private static let key = "account_id"

    public func boundAccount() throws -> UUID? {
        try writer.read { db in try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [Self.key]).flatMap(UUID.init(uuidString:)) }
    }

    public func check(userId: UUID) throws -> Check {
        guard let bound = try boundAccount() else { return .attachChoiceNeeded }
        return bound == userId ? .ready : .otherAccountOnDevice
    }

    /// Binds this device's data to `userId`. Without attaching, everything queued or unsent so far stays on the device
    /// (parked as `guest_local`, never pushed); later edits sync normally.
    public func bind(userId: UUID, attachLocalData: Bool) throws {
        try writer.write { db in
            if let bound = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [Self.key]), bound != DBText.id(userId) {
                throw ScopeError.otherAccountOnDevice
            }
            if !attachLocalData {
                try db.execute(sql: "UPDATE sync_outbox SET state = 'guest_local' WHERE state IN ('pending', 'sending', 'conflicted', 'rejected') AND payload_version = 2")
                for table in ["training_plans", "plan_activations", "plan_phases", "planned_workouts", "planned_exercises", "plan_goals", "body_measurements"] {
                    try db.execute(sql: "UPDATE \(table) SET dirty = 0")
                }
            }
            try db.execute(sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)", arguments: [Self.key, DBText.id(userId)])
        }
    }

    public enum ScopeError: Error, Equatable { case otherAccountOnDevice }

    /// Sign-out. Keeping the data leaves the account binding in place, so only the same account can sync it again.
    /// Deleting resets the content to the bundled seed, clears everything sync keeps (versions, cursor, inbox, outbox, device id)
    /// and unbinds.
    public func signOut(deleteLocalData: Bool, seed: ContentSeed?, now: Date = Date()) throws {
        guard deleteLocalData else { return }
        guard let seed else { throw ScopeError.otherAccountOnDevice }
        try ContentStore(writer: writer).resetAll(to: seed, now: now)
        try writer.write { db in try db.execute(sql: "DELETE FROM sync_state") }
    }
}
