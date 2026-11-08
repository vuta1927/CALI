import Foundation

/// How long a plan runs, which decides how "current week" is counted (D7, ADR-039).
public enum PlanProgram: Equatable, Hashable, Sendable {
    /// *Theo tuần*: counted in days actually followed. `totalWeeks == nil` when the length is not known
    /// (program length comes from phases, CON-005).
    // TODO(CON-005): derive totalWeeks from plan phases once CON-005 lands.
    case weekly(totalWeeks: Int?)
    /// *Sự kiện*: counted on the calendar up to the event day; paused weeks count as elapsed.
    case event(eventDate: LocalDate)
}

extension PlanProgram: Codable {
    private enum CodingKeys: String, CodingKey { case kind, totalWeeks, eventDate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "weekly": self = .weekly(totalWeeks: try c.decodeIfPresent(Int.self, forKey: .totalWeeks))
        case "event": self = .event(eventDate: try c.decode(LocalDate.self, forKey: .eventDate))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown plan kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .weekly(let weeks):
            try c.encode("weekly", forKey: .kind)
            try c.encodeIfPresent(weeks, forKey: .totalWeeks)
        case .event(let date):
            try c.encode("event", forKey: .kind)
            try c.encode(date, forKey: .eventDate)
        }
    }
}

/// Where a plan stands in its program on a given day.
public struct CurrentWeek: Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// No activation day yet up to today (draft, or first activation starts later).
        case notStarted
        case inProgress
        /// MP-07: weekly program completed, or the event day has passed. No planned or missed sessions
        /// from here until the user ends, extends or repeats the plan.
        case finished
    }

    public var state: State
    /// 1-based week number; 0 when not started. For a finished weekly plan it is `totalWeeks`.
    public var week: Int
    /// 1...7 within `week`; nil when not started, finished, or (weekly) paused today.
    public var dayInWeek: Int?
    /// Weekly: activation days before today. Event: calendar days since the first start.
    public var elapsedDays: Int
    /// Event plans only: days from today to the event day (negative after it).
    public var daysUntilEvent: Int?

    public init(state: State, week: Int, dayInWeek: Int?, elapsedDays: Int, daysUntilEvent: Int?) {
        self.state = state
        self.week = week
        self.dayInWeek = dayInWeek
        self.elapsedDays = elapsedDays
        self.daysUntilEvent = daysUntilEvent
    }
}

/// A planned workout's weekly slot (`planned_workout.id`, ISO `weekday` 1 = Monday ... 7 = Sunday).
public struct WeeklySlot: Equatable, Hashable, Sendable, Codable {
    public var plannedWorkoutId: UUID
    public var weekday: Int

    public init(plannedWorkoutId: UUID, weekday: Int) {
        self.plannedWorkoutId = plannedWorkoutId
        self.weekday = weekday
    }
}

/// The user moved one occurrence to another day. No contract defines this record yet; this is the minimal
/// shape the rule needs. Later entries for the same occurrence supersede earlier ones (ADR-052: the
/// schedule right after the latest reschedule counts).
// TODO(CON-005): align with the reschedule fields once a contract defines them.
public struct Reschedule: Equatable, Hashable, Sendable, Codable {
    public var plannedWorkoutId: UUID
    public var originalDate: LocalDate
    public var newDate: LocalDate

    public init(plannedWorkoutId: UUID, originalDate: LocalDate, newDate: LocalDate) {
        self.plannedWorkoutId = plannedWorkoutId
        self.originalDate = originalDate
        self.newDate = newDate
    }
}

/// A completed session as far as I4 is concerned. `plannedWorkoutId == nil` means the session is not linked
/// to any planned workout (free session, or a backfill the user did not link, ADR-054); it never counts.
/// `date` is the local day the session counts for.
public struct CompletedSessionRef: Equatable, Hashable, Sendable, Codable {
    public var sessionId: UUID
    public var lineageId: UUID?
    public var plannedWorkoutId: UUID?
    public var date: LocalDate
    /// Entered after the fact (ADR-054). Informational: linked backfills count like any other session.
    public var backfilled: Bool

    public init(sessionId: UUID, lineageId: UUID?, plannedWorkoutId: UUID?, date: LocalDate, backfilled: Bool = false) {
        self.sessionId = sessionId
        self.lineageId = lineageId
        self.plannedWorkoutId = plannedWorkoutId
        self.date = date
        self.backfilled = backfilled
    }

    private enum CodingKeys: String, CodingKey { case sessionId, lineageId, plannedWorkoutId, date, backfilled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(UUID.self, forKey: .sessionId)
        lineageId = try c.decodeIfPresent(UUID.self, forKey: .lineageId)
        plannedWorkoutId = try c.decodeIfPresent(UUID.self, forKey: .plannedWorkoutId)
        date = try c.decode(LocalDate.self, forKey: .date)
        backfilled = try c.decodeIfPresent(Bool.self, forKey: .backfilled) ?? false
    }
}

/// One planned occurrence of a plan, after reschedules.
public struct PlannedOccurrence: Equatable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case completed
        case missed
        /// Today or later and not completed yet.
        case pending
    }

    public var plannedWorkoutId: UUID
    /// The weekly slot's date before any reschedule.
    public var originalDate: LocalDate
    /// Where it counts (after the latest reschedule).
    public var date: LocalDate
    public var outcome: Outcome
    /// The session that satisfied it.
    public var sessionId: UUID?
}

public struct PlanAdherence: Equatable, Sendable {
    public var occurrences: [PlannedOccurrence]
    public var completedCount: Int { occurrences.filter { $0.outcome == .completed }.count }
    public var missedCount: Int { occurrences.filter { $0.outcome == .missed }.count }
    public var pendingCount: Int { occurrences.filter { $0.outcome == .pending }.count }
}

public enum PlanSchedule {
    /// D7 / ADR-039.
    /// - Weekly: `elapsedDays` = activation days strictly before today. Week = elapsed / 7 + 1, so a pause
    ///   resumes in the week that was in progress. Finished once elapsed days reach `7 × totalWeeks`.
    /// - Event: week counted on the calendar from the first activation's `fromDate`, pauses included.
    ///   Finished when today is after the event day.
    public static func currentWeek(program: PlanProgram, activations: [PlanActivation], today: LocalDate) -> CurrentWeek {
        let starts = activations.map(\.fromDate).sorted()
        guard let firstStart = starts.first, firstStart <= today else {
            var untilEvent: Int?
            if case .event(let date) = program { untilEvent = today.days(until: date) }
            return CurrentWeek(state: .notStarted, week: 0, dayInWeek: nil, elapsedDays: 0, daysUntilEvent: untilEvent)
        }
        switch program {
        case .weekly(let totalWeeks):
            let elapsed = followedDays(activations, before: today)
            let activeToday = activations.contains { $0.contains(today) }
            if let totalWeeks, elapsed >= totalWeeks * 7 {
                return CurrentWeek(state: .finished, week: totalWeeks, dayInWeek: nil, elapsedDays: elapsed, daysUntilEvent: nil)
            }
            return CurrentWeek(state: .inProgress, week: elapsed / 7 + 1, dayInWeek: activeToday ? elapsed % 7 + 1 : nil,
                               elapsedDays: elapsed, daysUntilEvent: nil)
        case .event(let eventDate):
            let elapsed = firstStart.days(until: today)
            let untilEvent = today.days(until: eventDate)
            if today > eventDate {
                // Week of the event day itself.
                let weekOfEvent = max(0, firstStart.days(until: eventDate)) / 7 + 1
                return CurrentWeek(state: .finished, week: weekOfEvent, dayInWeek: nil, elapsedDays: elapsed, daysUntilEvent: untilEvent)
            }
            return CurrentWeek(state: .inProgress, week: elapsed / 7 + 1, dayInWeek: elapsed % 7 + 1, elapsedDays: elapsed, daysUntilEvent: untilEvent)
        }
    }

    /// Planned occurrences whose (rescheduled) date lies in `from...through`. A weekly slot produces an
    /// occurrence on day D when D is inside an activation and inside the program (MP-07); a reschedule
    /// then moves it (ADR-052). An occurrence moved onto a day outside every activation or past the program
    /// end is dropped: such a day has no planned sessions for the plan (I4).
    public static func occurrences(
        program: PlanProgram,
        activations: [PlanActivation],
        slots: [WeeklySlot],
        reschedules: [Reschedule] = [],
        from: LocalDate,
        through: LocalDate
    ) -> [(plannedWorkoutId: UUID, originalDate: LocalDate, date: LocalDate)] {
        guard from <= through, let firstStart = activations.map(\.fromDate).min() else { return [] }
        var latest: [OccurrenceKey: LocalDate] = [:]
        for r in reschedules { latest[OccurrenceKey(r.plannedWorkoutId, r.originalDate)] = r.newDate }

        // Originals can sit outside the window and still be moved into it.
        let lower = max(firstStart, min(from, reschedules.map(\.originalDate).min() ?? from))
        let upper = max(through, reschedules.map(\.originalDate).max() ?? through)
        guard lower <= upper else { return [] }

        var result: [(UUID, LocalDate, LocalDate)] = []
        var day = lower
        while day <= upper {
            if isPlannedDay(day, program: program, activations: activations) {
                for slot in slots where slot.weekday == day.isoWeekday {
                    let date = latest[OccurrenceKey(slot.plannedWorkoutId, day)] ?? day
                    if from <= date, date <= through, isPlannedDay(date, program: program, activations: activations) {
                        result.append((slot.plannedWorkoutId, day, date))
                    }
                }
            }
            day = day.adding(days: 1)
        }
        return result
            .sorted { ($0.2, $0.0.uuidString, $0.1) < ($1.2, $1.0.uuidString, $1.1) }
            .map { (plannedWorkoutId: $0.0, originalDate: $0.1, date: $0.2) }
    }

    /// I4 for one plan, from its first activation through `today`:
    /// - an occurrence is completed by a session of this plan linked to the same planned workout on its date;
    ///   remaining occurrences of that date are then completed by the plan's other linked sessions that day;
    ///   each session satisfies at most one occurrence;
    /// - sessions of other plans, and unlinked sessions (including unlinked backfills, ADR-054), never count;
    /// - an occurrence before today that is not completed is missed; today's is pending until done.
    public static func adherence(
        lineageId: UUID,
        program: PlanProgram,
        activations: [PlanActivation],
        slots: [WeeklySlot],
        reschedules: [Reschedule] = [],
        sessions: [CompletedSessionRef],
        today: LocalDate
    ) -> PlanAdherence {
        guard let firstStart = activations.map(\.fromDate).min() else { return PlanAdherence(occurrences: []) }
        let planned = occurrences(program: program, activations: activations, slots: slots, reschedules: reschedules,
                                  from: firstStart, through: today)
        let workoutIds = Set(slots.map(\.plannedWorkoutId))
        var available = sessions
            .filter { $0.lineageId == lineageId && $0.plannedWorkoutId.map(workoutIds.contains) == true }
            .sorted { $0.sessionId.uuidString < $1.sessionId.uuidString }

        var matched = [UUID?](repeating: nil, count: planned.count)
        // Pass 1: exact (planned workout, date).
        for (i, occ) in planned.enumerated() {
            if let k = available.firstIndex(where: { $0.plannedWorkoutId == occ.plannedWorkoutId && $0.date == occ.date }) {
                matched[i] = available.remove(at: k).sessionId
            }
        }
        // Pass 2: another planned workout of the same plan done that day.
        for (i, occ) in planned.enumerated() where matched[i] == nil {
            if let k = available.firstIndex(where: { $0.date == occ.date }) {
                matched[i] = available.remove(at: k).sessionId
            }
        }

        let result = planned.enumerated().map { i, occ in
            let outcome: PlannedOccurrence.Outcome = matched[i] != nil ? .completed : (occ.date < today ? .missed : .pending)
            return PlannedOccurrence(plannedWorkoutId: occ.plannedWorkoutId, originalDate: occ.originalDate, date: occ.date,
                                     outcome: outcome, sessionId: matched[i])
        }
        return PlanAdherence(occurrences: result)
    }

    // MARK: Helpers

    /// Day D carries planned sessions of the plan: D is inside an activation and the program has not
    /// finished on D (weekly: D is within the first `7 × totalWeeks` followed days; event: D ≤ event day).
    static func isPlannedDay(_ day: LocalDate, program: PlanProgram, activations: [PlanActivation]) -> Bool {
        guard activations.contains(where: { $0.contains(day) }) else { return false }
        switch program {
        case .weekly(let totalWeeks):
            guard let totalWeeks else { return true }
            return followedDays(activations, before: day) < totalWeeks * 7
        case .event(let eventDate):
            return day <= eventDate
        }
    }

    /// Number of activation days strictly before `day` (activations of one plan never overlap, I1).
    static func followedDays(_ activations: [PlanActivation], before day: LocalDate) -> Int {
        activations.reduce(0) { sum, a in
            guard a.fromDate < day else { return sum }
            let lastCounted = min(a.toDate ?? day.adding(days: -1), day.adding(days: -1))
            return sum + a.fromDate.days(until: lastCounted) + 1
        }
    }

    private struct OccurrenceKey: Hashable {
        let workout: UUID
        let date: LocalDate
        init(_ workout: UUID, _ date: LocalDate) {
            self.workout = workout
            self.date = date
        }
    }
}
