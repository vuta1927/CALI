import CaliCore
import CaliDomain
import XCTest
@testable import CaliApp

/// IOS-017: History across plans (missed / today / filter) and the "Tuần này" card.
final class HistoryFlowTests: XCTestCase {
    private let tenDaysAgo = Date().addingTimeInterval(-10 * 86_400)

    @MainActor
    private func makeStore() throws -> AppStore {
        let store = AppStore(now: tenDaysAgo, database: try AppDatabase.inMemory())
        store.updateSettings { $0.notificationsEnabled = false; $0.liveActivityEnabled = false; $0.countdownSeconds = 0 }
        return store
    }

    /// A running plan with a workout every day of the week, followed since ten days ago, so every earlier
    /// day of the current week is a missed one.
    @MainActor
    private func makeRunPlan(_ store: AppStore) throws -> UUID {
        let id = try XCTUnwrap(store.createPlan(PlanDraft(title: "Chạy bán marathon", discipline: .running), now: tenDaysAgo))
        for weekday in 1...7 {
            let item = PlannedExercise(id: UUID(), exerciseId: MockData.easyRun, setCount: 1,
                                       target: .distance(distanceMeters: 8_000, durationSeconds: nil), restSeconds: 0)
            XCTAssertTrue(store.updateWorkout(PlannedWorkout(id: UUID(), weekday: weekday, title: "Chạy \(weekday)", focus: "", exercises: [item]), in: id))
        }
        XCTAssertTrue(store.startPlan(id, from: store.today(tenDaysAgo), now: tenDaysAgo))
        return id
    }

    /// Records a completed 8,25 km run for today's workout of the plan.
    @MainActor
    private func recordTodaysRun(_ store: AppStore, plan lineage: UUID) throws {
        let today = store.today()
        let items = store.scheduledItems(on: today).filter { $0.plan.lineageId == lineage }
        let item = try XCTUnwrap(items.first)
        let planned = item.workout.exercises[0]
        let spec = ExecutionSpec(id: UUID(), plannedExerciseId: planned.id, exerciseId: planned.exerciseId, catalogVersion: MockData.catalogVersion,
                                 setCount: 1, target: planned.target, restSeconds: 0)
        let commands: [Command] = [
            .createSession(CreateSession(commandId: UUID(), sessionId: UUID(), plannedWorkoutId: item.workout.id, executions: [spec])),
            .startSet(StartSet(commandId: UUID(), countdownSeconds: 0)), .stopSet(SimpleCommand(commandId: UUID())),
            .confirmSet(ConfirmSet(commandId: UUID(), setResultId: UUID(), executionId: spec.id, setIndex: 1, status: .completed,
                                   actualDistanceMeters: 8_250, actualDurationSeconds: 2_538)),
            .finishSession(SimpleCommand(commandId: UUID())),
        ]
        let result = try store.recordSession(commands, sessionTitle: item.workout.title, audit: AuditEntry(id: UUID(), at: Date(), action: "test", detail: ""))
        XCTAssertEqual(result.outcome.status, .applied)
        store.reloadContent()
    }

    @MainActor
    func testPastDaysOfAFollowedPlanAreMissedAndTodayIsOpen() throws {
        let store = try makeStore()
        let plan = try makeRunPlan(store)
        let today = store.today()
        let items = store.scheduledItems(from: today.adding(days: -3), through: today.adding(days: 1), includeEnded: true)
            .filter { $0.plan.lineageId == plan }
        XCTAssertEqual(items.filter { $0.date < today }.map(\.outcome), [.missed, .missed, .missed])
        XCTAssertEqual(items.first { $0.date == today }?.outcome, .pending)
        XCTAssertEqual(items.first { $0.date > today }?.outcome, .pending)
        let slot = try XCTUnwrap(items.first { $0.date == today }).slot
        XCTAssertEqual(HistoryDayState.of(day: today, sessions: [], slots: [slot], today: today), .today)
    }

    @MainActor
    func testWeekCardSumsEveryPlanAndKeepsKilometresSeparate() throws {
        let store = try makeStore()
        let plan = try makeRunPlan(store)
        let before = store.weekSummary()
        XCTAssertEqual(before.done, 0)
        XCTAssertTrue(before.perPlan.contains { $0.lineageId == plan && $0.scheduled == 7 })

        try recordTodaysRun(store, plan: plan)
        let week = store.weekSummary()
        XCTAssertEqual(week.done, 1)
        XCTAssertEqual(week.distanceMeters, 8_250)
        XCTAssertEqual(week.perPlan.first { $0.lineageId == plan }?.done, 1)
        // Due = days that passed, plus today's when done; every plan in the schedule counts (all plans, not only this one).
        let today = store.today(), monday = store.monday(of: today)
        let items = store.scheduledItems(from: monday, through: monday.adding(days: 6))
        XCTAssertEqual(week.scheduled, items.count)
        XCTAssertEqual(week.due, items.filter { $0.date < today || $0.isDone }.count)
        XCTAssertEqual(week.adherencePercent, (week.done * 100 + week.due / 2) / week.due)
        XCTAssertEqual(week.perPlan.map(\.scheduled).reduce(0, +), week.scheduled)
    }

    @MainActor
    func testHistoryFilterListsPlansWithSessionsAndKeepsDeletedOnes() throws {
        let store = try makeStore()
        let plan = try makeRunPlan(store)
        try recordTodaysRun(store, plan: plan)
        XCTAssertTrue(store.historyPlanOptions().contains { $0.lineageId == plan && $0.title == "Chạy bán marathon" })
        XCTAssertTrue(store.deletePlan(plan))
        let option = try XCTUnwrap(store.historyPlanOptions().first { $0.lineageId == plan })
        XCTAssertEqual(option.title, "Chạy bán marathon (đã xoá)", "the sessions stay, labelled")
        XCTAssertEqual(store.history.filter { $0.planLineageId == plan }.count, 1)
    }

    @MainActor
    func testEndedPlansOnlyShowTheirPastWhenAsked() throws {
        let store = try makeStore()
        let plan = try makeRunPlan(store)
        XCTAssertTrue(store.endPlan(plan, reason: .stopped))
        let today = store.today()
        let range = (today.adding(days: -3), today)
        XCTAssertTrue(store.scheduledItems(from: range.0, through: range.1).filter { $0.plan.lineageId == plan }.isEmpty)
        XCTAssertFalse(store.scheduledItems(from: range.0, through: range.1, includeEnded: true).filter { $0.plan.lineageId == plan }.isEmpty)
    }
}
