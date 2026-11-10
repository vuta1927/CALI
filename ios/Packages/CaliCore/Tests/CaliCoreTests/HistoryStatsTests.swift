import CaliDomain
import XCTest
@testable import CaliCore

/// IOS-017: period comparison, day states and the cross-plan week summary.
final class HistoryStatsTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func local(_ y: Int, _ m: Int, _ d: Int) -> LocalDate { LocalDate(year: y, month: m, day: d)! }

    private func session(_ day: Date, status: SessionStatus = .completed, minutes: Int = 30, sets: [LoggedSet] = []) -> CompletedSession {
        CompletedSession(id: UUID(), title: "T", plannedWorkoutId: nil, startedAt: day, finishedAt: day.addingTimeInterval(Double(minutes) * 60),
                         status: status, exerciseIds: [], plannedSetCount: 0, sets: sets, isSample: false)
    }

    private func slot(_ plan: UUID, _ title: String, _ day: LocalDate, _ outcome: PlannedOccurrence.Outcome) -> ScheduleSlot {
        ScheduleSlot(lineageId: plan, planTitle: title, workoutTitle: "W", date: day, outcome: outcome)
    }

    // 2026-11-11 is a Wednesday, so the week in progress is Mon 9 … Sun 15 and today is not finished.
    func testWeekInProgressComparesTheSameElapsedDaysAndLeavesTodayOut() {
        let now = date(2026, 11, 11)
        let oldest = date(2026, 10, 1)
        guard case .compare(let current, let previous, let days) = HistoryPeriods.comparison(.week, offset: 0, oldest: oldest, now: now, calendar: calendar) else {
            return XCTFail("expected a comparison")
        }
        XCTAssertEqual(days, 2, "Mon and Tue are over")
        XCTAssertEqual(current, DateInterval(start: date(2026, 11, 9, 0), end: date(2026, 11, 11, 0)))
        XCTAssertEqual(previous, DateInterval(start: date(2026, 11, 2, 0), end: date(2026, 11, 4, 0)))
    }

    func testFinishedWeekComparesWithTheWholeWeekBefore() {
        let now = date(2026, 11, 11)
        guard case .compare(let current, let previous, let days) = HistoryPeriods.comparison(.week, offset: 1, oldest: date(2026, 10, 1), now: now, calendar: calendar) else {
            return XCTFail("expected a comparison")
        }
        XCTAssertNil(days)
        XCTAssertEqual(current.duration, 7 * 86_400, accuracy: 1)
        XCTAssertEqual(previous.end, current.start)
    }

    func testOldestPeriodAndFirstDayHaveNothingToCompare() {
        let now = date(2026, 11, 9) // Monday: no finished day yet
        XCTAssertEqual(HistoryPeriods.comparison(.week, offset: 0, oldest: date(2026, 10, 1), now: now, calendar: calendar), .notEnoughDays)
        XCTAssertEqual(HistoryPeriods.comparison(.week, offset: 0, oldest: date(2026, 11, 10), now: now, calendar: calendar), .firstPeriod)
        XCTAssertEqual(HistoryPeriods.comparison(.month, offset: 0, oldest: nil, now: now, calendar: calendar), .firstPeriod)
    }

    func testMonthInProgressUsesTheSameDaysOfThePreviousMonth() {
        let now = date(2026, 3, 31) // previous month (February) is shorter
        guard case .compare(_, let previous, let days) = HistoryPeriods.comparison(.month, offset: 0, oldest: date(2025, 12, 1), now: now, calendar: calendar) else {
            return XCTFail("expected a comparison")
        }
        XCTAssertEqual(days, 30)
        XCTAssertEqual(previous.end, date(2026, 3, 1, 0), "clamped to the end of February")
    }

    func testDayStates() {
        let today = local(2026, 11, 11), plan = UUID()
        let done = session(date(2026, 11, 9)), stopped = session(date(2026, 11, 9), status: .abandoned)
        XCTAssertEqual(HistoryDayState.of(day: local(2026, 11, 9), sessions: [done], slots: [slot(plan, "A", local(2026, 11, 9), .completed)], today: today), .done)
        XCTAssertEqual(HistoryDayState.of(day: local(2026, 11, 9), sessions: [stopped], slots: [slot(plan, "A", local(2026, 11, 9), .missed)], today: today), .stoppedEarly)
        XCTAssertEqual(HistoryDayState.of(day: local(2026, 11, 10), sessions: [], slots: [slot(plan, "A", local(2026, 11, 10), .missed)], today: today), .missed)
        XCTAssertEqual(HistoryDayState.of(day: today, sessions: [], slots: [slot(plan, "A", today, .pending)], today: today), .today)
        XCTAssertEqual(HistoryDayState.of(day: local(2026, 11, 12), sessions: [], slots: [slot(plan, "A", local(2026, 11, 12), .pending)], today: today), .planned)
        XCTAssertEqual(HistoryDayState.of(day: local(2026, 11, 10), sessions: [], slots: [], today: today), .rest)
    }

    func testWeekSummaryAcrossPlansMatchesTheAcceptanceScenario() {
        // docs/19 §8: Calisthenics 3/3, Chạy 2/4 with 18,5 km → 5/7 sessions, 71%, 18,5 km. The week is over.
        let cali = UUID(), run = UUID(), today = local(2026, 11, 16)
        var slots = (9...11).map { slot(cali, "Calisthenics", local(2026, 11, $0), .completed) }
        slots += [slot(run, "Chạy bán marathon", local(2026, 11, 9), .completed), slot(run, "Chạy bán marathon", local(2026, 11, 11), .completed),
                  slot(run, "Chạy bán marathon", local(2026, 11, 13), .missed), slot(run, "Chạy bán marathon", local(2026, 11, 15), .missed)]
        let legs = [LoggedSet.running(meters: 10_000), LoggedSet.running(meters: 8_500)]
        let sessions = (0..<3).map { _ in session(date(2026, 11, 10), sets: []) } + [session(date(2026, 11, 9), sets: [legs[0]]), session(date(2026, 11, 11), sets: [legs[1]])]
        let week = WeekSummary(slots: slots, sessions: sessions, today: today)
        XCTAssertEqual(week.done, 5)
        XCTAssertEqual(week.scheduled, 7)
        XCTAssertEqual(week.adherencePercent, 71)
        XCTAssertEqual(week.distanceMeters, 18_500)
        XCTAssertEqual(week.perPlan.map(\.title), ["Calisthenics", "Chạy bán marathon"])
        XCTAssertEqual(week.perPlan.map { "\($0.done)/\($0.scheduled)" }, ["3/3", "2/4"])
        XCTAssertEqual(week.extraSessions, 0)
    }

    func testAdherenceIgnoresDaysThatAreNotDueYet() {
        let plan = UUID(), today = local(2026, 11, 11)
        let slots = [slot(plan, "A", local(2026, 11, 9), .completed), slot(plan, "A", local(2026, 11, 10), .missed),
                     slot(plan, "A", today, .pending), slot(plan, "A", local(2026, 11, 13), .pending)]
        let week = WeekSummary(slots: slots, sessions: [session(date(2026, 11, 9))], today: today)
        XCTAssertEqual(week.scheduled, 4)
        XCTAssertEqual(week.due, 2, "today and Friday are not due")
        XCTAssertEqual(week.adherencePercent, 50)
        XCTAssertNil(WeekSummary(slots: [slot(plan, "A", local(2026, 11, 13), .pending)], sessions: [], today: today).adherencePercent)
    }

    func testTotalsKeepSetsAndDistanceSeparateAndSkipSkippedSets() {
        var skipped = LoggedSet.running(meters: 5_000)
        skipped.status = .skipped
        let totals = PeriodTotals([session(date(2026, 11, 9), minutes: 40, sets: [.running(meters: 8_000), skipped]),
                                   session(date(2026, 11, 10), status: .abandoned, minutes: 10)])
        XCTAssertEqual(totals.sessionsDone, 1)
        XCTAssertEqual(totals.sessionsStoppedEarly, 1)
        XCTAssertEqual(totals.minutes, 50)
        XCTAssertEqual(totals.distanceMeters, 8_000)
        XCTAssertEqual(totals.setsDone, 1)
    }

    func testFreeSessionsCountAsExtraNotInTheSchedule() {
        let plan = UUID()
        let week = WeekSummary(slots: [slot(plan, "A", local(2026, 11, 9), .completed)],
                               sessions: [session(date(2026, 11, 9)), session(date(2026, 11, 10))], today: local(2026, 11, 12))
        XCTAssertEqual(week.extraSessions, 1)
    }
}

private extension LoggedSet {
    static func running(meters: Int) -> LoggedSet {
        LoggedSet(id: UUID(), exerciseId: UUID(), setIndex: 1, status: .completed, target: .distance(distanceMeters: meters, durationSeconds: nil),
                  distanceMeters: meters, durationSeconds: 3000)
    }
}
