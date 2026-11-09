import CaliCore
import CaliDomain
import XCTest
@testable import CaliApp

/// IOS-015: goals, roadmap and progress (docs/18 §6). A goal is never achieved without the user.
final class GoalFlowTests: XCTestCase {
    @MainActor
    private func makeStore() throws -> AppStore {
        let store = AppStore(now: Date().addingTimeInterval(-10 * 86_400), database: try AppDatabase.inMemory())
        store.updateSettings { $0.notificationsEnabled = false; $0.liveActivityEnabled = false; $0.countdownSeconds = 0 }
        return store
    }

    /// The first reps exercise of the starter plan and its workout.
    @MainActor
    private func repsItem(_ store: AppStore) throws -> (workout: PlannedWorkout, item: PlannedExercise) {
        for workout in store.starterPlan.workouts {
            if let item = workout.exercises.first(where: { store.exercise($0.exerciseId)?.type == .reps }) { return (workout, item) }
        }
        throw XCTSkip("starter plan has no reps exercise")
    }

    @MainActor
    private func goal(_ store: AppStore, exerciseId: UUID, target: Decimal, indicator: String = "best_set_reps", pinned: Bool = false) -> PlanGoal {
        PlanGoal(id: UUID(), planLineageId: store.starterPlan.lineageId, title: "Mục tiêu \(target)", indicatorId: indicator,
                 exerciseId: exerciseId, target: .value(target), pinned: pinned)
    }

    /// Saves one completed session of `reps` for the planned item through the coordinator.
    @MainActor
    private func record(_ store: AppStore, _ pair: (workout: PlannedWorkout, item: PlannedExercise), reps: Int) throws -> UUID {
        let sessionId = UUID()
        let execution = ExecutionSpec(id: UUID(), plannedExerciseId: pair.item.id, exerciseId: pair.item.exerciseId,
                                      catalogVersion: store.exercise(pair.item.exerciseId)?.catalogVersion ?? MockData.catalogVersion,
                                      setCount: 1, target: pair.item.target, restSeconds: 0)
        let commands: [Command] = [
            .createSession(CreateSession(commandId: UUID(), sessionId: sessionId, plannedWorkoutId: pair.workout.id, executions: [execution])),
            .startSet(StartSet(commandId: UUID(), countdownSeconds: 0)),
            .stopSet(SimpleCommand(commandId: UUID())),
            .confirmSet(ConfirmSet(commandId: UUID(), setResultId: UUID(), executionId: execution.id, setIndex: 1, status: .completed, actualReps: reps)),
            .finishSession(SimpleCommand(commandId: UUID())),
        ]
        let result = try store.recordSession(commands, sessionTitle: pair.workout.title, audit: AuditEntry(id: UUID(), at: Date(), action: "test", detail: ""))
        XCTAssertEqual(result.outcome.status, .applied)
        store.reloadContent()
        return sessionId
    }

    @MainActor
    func testReachingTheTargetOnlyAsksForConfirmation() throws {
        let store = try makeStore()
        let pair = try repsItem(store)
        let g = goal(store, exerciseId: pair.item.exerciseId, target: 10, pinned: true)
        let command = UUID()
        XCTAssertTrue(store.saveGoal(g, commandId: command))
        XCTAssertTrue(store.saveGoal(g, commandId: command), "replay is safe")
        XCTAssertEqual(store.audit.filter { $0.id == command }.count, 1)

        let low = try record(store, pair, reps: 8)
        store.flagReachedGoals(after: low)
        XCTAssertEqual(store.goal(g.id)?.status, .active)
        XCTAssertEqual(store.current(of: try XCTUnwrap(store.goal(g.id))), 8)

        let high = try record(store, pair, reps: 12)
        store.flagReachedGoals(after: high)
        let reached = try XCTUnwrap(store.goal(g.id))
        XCTAssertEqual(reached.status, .reached, "waiting for the user, never achieved automatically")
        XCTAssertNil(reached.achievedAt)

        XCTAssertTrue(store.keepGoal(g.id))
        XCTAssertEqual(store.goal(g.id)?.status, .active)
        XCTAssertTrue(store.confirmGoal(g.id))
        let achieved = try XCTUnwrap(store.goal(g.id))
        XCTAssertEqual(achieved.status, .achieved)
        XCTAssertNotNil(achieved.achievedAt)
        XCTAssertFalse(achieved.pinned)
        XCTAssertEqual(store.audit.first?.action, "Xác nhận đạt mục tiêu")
    }

    @MainActor
    func testPinnedLimitAndImmutableIndicatorAndExercise() throws {
        let store = try makeStore()
        let pair = try repsItem(store)
        let goals = (0..<4).map { goal(store, exerciseId: pair.item.exerciseId, target: Decimal(10 + $0), pinned: $0 < 3) }
        for g in goals { XCTAssertTrue(store.saveGoal(g)) }
        XCTAssertFalse(store.setPinned(goals[3].id, true))
        XCTAssertNotNil(store.alertMessage)

        var changed = goals[0]
        changed.indicatorId = "milestone_reps"
        XCTAssertFalse(store.saveGoal(changed), "ADR-047: a different indicator is a new goal")
        var wrong = goal(store, exerciseId: pair.item.exerciseId, target: 10, indicator: "best_hold_seconds")
        wrong.pinned = false
        XCTAssertFalse(store.saveGoal(wrong), "a hold indicator does not fit a reps exercise")
    }

    @MainActor
    func testRoadmapSetsLengthAndRescopesGoalsOfRemovedPhases() throws {
        let store = try makeStore()
        let lineage = store.starterPlan.lineageId
        let base = PlanPhase(id: UUID(), name: "Nền tảng", weeks: 4)
        let peak = PlanPhase(id: UUID(), name: "Tăng", weeks: 3)
        XCTAssertTrue(store.savePhases(lineage, [base, peak]))
        XCTAssertEqual(store.starterPlan.program, .weekly(totalWeeks: 7))
        XCTAssertEqual(store.phaseSpans(of: store.starterPlan).map(\.label), ["Tuần 1–4", "Tuần 5–7"])
        XCTAssertEqual(store.phaseSpans(of: store.starterPlan).first?.state, .current, "started ten days ago: week 2")
        XCTAssertEqual(store.audit.first?.action, "Sửa lộ trình")

        let pair = try repsItem(store)
        var scoped = goal(store, exerciseId: pair.item.exerciseId, target: 20)
        scoped.scopePhaseId = peak.id
        XCTAssertTrue(store.saveGoal(scoped))
        XCTAssertTrue(store.savePhases(lineage, [base]))
        XCTAssertNil(store.goal(scoped.id)?.scopePhaseId, "goals of a removed phase move to the whole plan")
        XCTAssertFalse(store.savePhases(lineage, [PlanPhase(id: UUID(), name: "Quá dài", weeks: 53)]))
    }

    @MainActor
    func testEndingThePlanMarksPursuedGoalsMissedAndTheyCanBeExtendedOrArchived() throws {
        let store = try makeStore()
        let pair = try repsItem(store)
        let g = goal(store, exerciseId: pair.item.exerciseId, target: 50)
        XCTAssertTrue(store.saveGoal(g))
        XCTAssertTrue(store.endPlan(store.starterPlan.lineageId, reason: .stopped))
        XCTAssertEqual(store.goal(g.id)?.status, .missed)
        XCTAssertNil(store.goal(g.id)?.achievedAt)
        XCTAssertTrue(store.archiveGoal(g.id))
        XCTAssertTrue(store.restoreGoal(g.id))
        XCTAssertEqual(store.goal(g.id)?.status, .active)
    }

    @MainActor
    func testProgressAndAdherenceComeFromSavedSets() throws {
        let store = try makeStore()
        let pair = try repsItem(store)
        _ = try record(store, pair, reps: 9)
        let row = try XCTUnwrap(store.exerciseProgress(of: store.starterPlan).first { $0.exercise.id == pair.item.exerciseId })
        XCTAssertEqual(row.summary.current, 9)
        XCTAssertNil(row.summary.reference, "one week of data: nothing to compare yet")
        XCTAssertEqual(GoalFmt.delta(row.summary, unit: "lần"), "Chưa đủ dữ liệu để so")
        let weeks = store.weeklyAdherence(of: store.starterPlan)
        XCTAssertEqual(weeks.first?.week, 1)
        XCTAssertGreaterThanOrEqual(weeks.reduce(0) { $0 + $1.done }, 1)
    }
}
