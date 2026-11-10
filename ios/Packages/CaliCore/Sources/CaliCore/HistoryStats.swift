import CaliDomain
import Foundation

// IOS-017 / UX-10 (docs/02 §3.1): pure rules behind the History tab and the "Tuần này" card.
// Nothing here writes; every number is derived from recorded sessions and the plan schedule.

/// Totals of a set of sessions. Sets and kilometres are separate on purpose: a set count and a distance
/// are never added together (docs/19 §3).
public struct PeriodTotals: Equatable, Sendable {
    public var sessionsDone = 0
    /// Sessions that ended early; shown as a neutral count, never as a failure.
    public var sessionsStoppedEarly = 0
    public var setsDone = 0
    public var minutes = 0
    /// Distance of the non-skipped running sets, metres.
    public var distanceMeters = 0

    public init() {}

    public init(_ sessions: [CompletedSession]) {
        for session in sessions {
            if session.status == .completed { sessionsDone += 1 } else { sessionsStoppedEarly += 1 }
            setsDone += session.completedSetCount
            minutes += session.durationMinutes
            distanceMeters += session.sets.filter { $0.status != .skipped }.reduce(0) { $0 + ($1.distanceMeters ?? 0) }
        }
    }
}

public enum HistoryPeriodKind: Sendable { case week, month }

/// How the period in view is compared with the one before it.
public enum PeriodComparison: Equatable, Sendable {
    /// The oldest period with data: nothing earlier to compare with.
    case firstPeriod
    /// The period in progress has no finished day yet (today is excluded), so there is nothing to compare.
    case notEnoughDays
    /// `elapsedDays` is set for the period in progress: the same first days of the previous period are used.
    case compare(current: DateInterval, previous: DateInterval, elapsedDays: Int?)
}

public enum HistoryPeriods {
    /// Monday-first week or calendar month `offset` periods before the one containing `now`.
    public static func interval(_ kind: HistoryPeriodKind, offset: Int, now: Date, calendar: Calendar) -> DateInterval {
        let component: Calendar.Component = kind == .week ? .weekOfYear : .month
        let current = calendar.dateInterval(of: component, for: now)!
        let start = calendar.date(byAdding: component, value: -offset, to: current.start)!
        return calendar.dateInterval(of: component, for: start)!
    }

    /// Oldest offset that still holds data; navigation stops there.
    public static func maxOffset(_ kind: HistoryPeriodKind, oldest: Date?, now: Date, calendar: Calendar) -> Int {
        guard let oldest else { return 0 }
        let component: Calendar.Component = kind == .week ? .weekOfYear : .month
        let a = calendar.dateInterval(of: component, for: oldest)!.start
        let b = calendar.dateInterval(of: component, for: now)!.start
        return max(0, calendar.dateComponents([component], from: a, to: b).value(for: component) ?? 0)
    }

    /// docs/02 §3.1: for the period in progress compare the same elapsed days of the previous period and leave
    /// today out; a finished period is compared with the whole one before it.
    public static func comparison(_ kind: HistoryPeriodKind, offset: Int, oldest: Date?, now: Date, calendar: Calendar) -> PeriodComparison {
        guard offset < maxOffset(kind, oldest: oldest, now: now, calendar: calendar) else { return .firstPeriod }
        let current = interval(kind, offset: offset, now: now, calendar: calendar)
        let previous = interval(kind, offset: offset + 1, now: now, calendar: calendar)
        guard offset == 0 else { return .compare(current: current, previous: previous, elapsedDays: nil) }
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: current.start, to: today).day ?? 0
        guard days > 0 else { return .notEnoughDays }
        let previousEnd = min(calendar.date(byAdding: .day, value: days, to: previous.start)!, previous.end)
        return .compare(current: DateInterval(start: current.start, end: today),
                        previous: DateInterval(start: previous.start, end: previousEnd), elapsedDays: days)
    }
}

/// One planned workout on a day, with its I4 outcome (`PlanSchedule.adherence`).
public struct ScheduleSlot: Equatable, Sendable {
    public var lineageId: UUID
    public var planTitle: String
    public var workoutTitle: String
    public var date: LocalDate
    public var outcome: PlannedOccurrence.Outcome

    public init(lineageId: UUID, planTitle: String, workoutTitle: String, date: LocalDate, outcome: PlannedOccurrence.Outcome) {
        self.lineageId = lineageId
        self.planTitle = planTitle
        self.workoutTitle = workoutTitle
        self.date = date
        self.outcome = outcome
    }
}

public enum HistoryDayState: Equatable, Sendable {
    /// Nothing recorded or scheduled.
    case rest
    case done
    /// Only sessions that ended early (warning, never red).
    case stoppedEarly
    /// Scheduled in the past with no completed session; shown dashed and not tappable.
    case missed
    /// Scheduled today and not done yet; opens Today.
    case today
    /// Scheduled in the future; a dashed dot only, never a list row.
    case planned

    /// `sessions` are the ones that started on `day`; `slots` the planned workouts of `day`.
    public static func of(day: LocalDate, sessions: [CompletedSession], slots: [ScheduleSlot], today: LocalDate) -> HistoryDayState {
        if sessions.contains(where: { $0.status == .completed }) { return .done }
        if !sessions.isEmpty { return .stoppedEarly }
        if day > today { return slots.isEmpty ? .rest : .planned }
        if slots.contains(where: { $0.outcome == .missed }) { return .missed }
        if day == today, slots.contains(where: { $0.outcome == .pending }) { return .today }
        return .rest
    }
}

public struct PlanWeekLine: Equatable, Identifiable, Sendable {
    public var lineageId: UUID
    public var title: String
    public var done: Int
    public var scheduled: Int
    public var id: UUID { lineageId }
}

/// The "Tuần này" card across every plan (docs/19 §8 "Tổng hợp tuần qua mọi giáo án").
public struct WeekSummary: Equatable, Sendable {
    /// Planned sessions of the week, and how many of them are done.
    public var scheduled = 0
    public var done = 0
    /// Planned sessions that are already due: past days, plus any that are done today.
    public var due = 0
    /// Completed sessions beyond the schedule (free sessions, extra days).
    public var extraSessions = 0
    public var minutes = 0
    public var distanceMeters = 0
    public var perPlan: [PlanWeekLine] = []

    /// Done ÷ due, whole percent; nil before anything is due. A missed session only lowers this number.
    public var adherencePercent: Int? { due == 0 ? nil : (done * 100 + due / 2) / due }

    public init() {}

    /// `slots`: planned workouts of Monday…Sunday of every followed plan; `sessions`: the sessions recorded in
    /// that week (any status, stopped-early ones are ignored for the totals below).
    public init(slots: [ScheduleSlot], sessions: [CompletedSession], today: LocalDate) {
        let completed = sessions.filter { $0.status == .completed }
        var lines: [UUID: PlanWeekLine] = [:]
        var order: [UUID] = []
        for slot in slots {
            if lines[slot.lineageId] == nil {
                lines[slot.lineageId] = PlanWeekLine(lineageId: slot.lineageId, title: slot.planTitle, done: 0, scheduled: 0)
                order.append(slot.lineageId)
            }
            lines[slot.lineageId]?.scheduled += 1
            scheduled += 1
            let isDone = slot.outcome == .completed
            if isDone {
                lines[slot.lineageId]?.done += 1
                done += 1
            }
            if isDone || slot.date < today { due += 1 }
        }
        perPlan = order.compactMap { lines[$0] }
        extraSessions = max(0, completed.count - done)
        let totals = PeriodTotals(completed)
        minutes = totals.minutes
        distanceMeters = totals.distanceMeters
    }
}
