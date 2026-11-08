import Foundation

/// A reminder the app would like to schedule for one planned occurrence (MP-13). `fireAt` is an absolute
/// UTC instant the caller computed from the occurrence's local date, its reminder time and the zone.
public struct ReminderCandidate: Equatable, Hashable, Sendable, Codable {
    public var lineageId: UUID
    public var plannedWorkoutId: UUID
    public var fireAt: Date

    public init(lineageId: UUID, plannedWorkoutId: UUID, fireAt: Date) {
        self.lineageId = lineageId
        self.plannedWorkoutId = plannedWorkoutId
        self.fireAt = fireAt
    }
}

/// One local notification to schedule: every candidate due in the same minute, merged
/// ("2 buổi lúc 6:00").
public struct ScheduledReminder: Equatable, Hashable, Sendable {
    /// Start of the minute the reminders fall in.
    public var fireAt: Date
    /// Sorted by lineage, then planned workout.
    public var items: [ReminderCandidate]
    /// Stable request identifier, so rescheduling on every app open replaces rather than duplicates.
    public var identifier: String

    public var count: Int { items.count }
}

/// Picks which reminders go to the system. Notifications are advisory only: they never change workout or
/// plan state (AGENTS: a notification may be late or missed).
public enum ReminderSelection {
    /// iOS keeps at most 64 pending local notifications per app.
    public static let systemPendingLimit = 64

    /// Nearest first across all plans: drops anything not strictly after `now`, merges candidates of the same
    /// minute into one notification and keeps the first `limit` notifications. Deterministic for equal input.
    public static func select(_ candidates: [ReminderCandidate], now: Date, limit: Int = systemPendingLimit) -> [ScheduledReminder] {
        guard limit > 0 else { return [] }
        var byMinute: [Int64: [ReminderCandidate]] = [:]
        for c in candidates where c.fireAt > now {
            byMinute[minute(of: c.fireAt), default: []].append(c)
        }
        return byMinute.keys.sorted().prefix(limit).map { key in
            // The same occurrence listed twice in one minute is one reminder.
            var seen = Set<String>()
            let items = byMinute[key]!
                .sorted { $0.fireAt < $1.fireAt }
                .filter { seen.insert("\($0.lineageId)|\($0.plannedWorkoutId)").inserted }
                .sorted { ($0.lineageId.uuidString, $0.plannedWorkoutId.uuidString) < ($1.lineageId.uuidString, $1.plannedWorkoutId.uuidString) }
            return ScheduledReminder(fireAt: Date(timeIntervalSince1970: TimeInterval(key * 60)), items: items,
                                     identifier: "cali.reminder.\(key * 60)")
        }
    }

    /// Whole minutes since 1970 (floor), so reminders set at 06:00:00 and 06:00:30 merge.
    private static func minute(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 60).rounded(.down))
    }
}
