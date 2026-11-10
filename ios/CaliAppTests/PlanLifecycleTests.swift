import CaliCore
import CaliDomain
import XCTest
@testable import CaliApp

/// IOS-013: several plans, lifecycle commands and the merged schedule (docs/19).
final class PlanLifecycleTests: XCTestCase {
    /// The starter plan was activated ten days ago, so pausing closes (not cancels) its activation.
    @MainActor
    private func makeStore(_ database: AppDatabase? = nil) throws -> AppStore {
        let store = AppStore(now: Date().addingTimeInterval(-10 * 86_400), database: try database ?? AppDatabase.inMemory())
        store.updateSettings { $0.notificationsEnabled = false; $0.liveActivityEnabled = false; $0.countdownSeconds = 0 }
        return store
    }

    @MainActor
    private func template(_ store: AppStore, _ title: String) throws -> UUID {
        try XCTUnwrap(sampleWorkouts(store, PlanDraft(title: title)))
    }

    /// A new plan with the workouts of the in-memory sample plan (the app itself no longer offers a template).
    @MainActor
    private func sampleWorkouts(_ store: AppStore, _ draft: PlanDraft) -> UUID? {
        guard let id = store.createPlan(draft) else { return nil }
        for workout in MockData.plan.workouts {
            var copy = workout
            copy.id = UUID()
            copy.exercises = copy.exercises.map { var item = $0; item.id = UUID(); return item }
            _ = store.updateWorkout(copy, in: id)
        }
        return id
    }

    @MainActor
    func testCreateIsIdempotentAndSavesADraft() throws {
        let store = try makeStore()
        let command = UUID()
        let id = try XCTUnwrap(store.createPlan(PlanDraft(title: "Gym"), commandId: command))
        XCTAssertEqual(store.createPlan(PlanDraft(title: "Gym"), commandId: command), id)
        XCTAssertEqual(store.visiblePlans.count, 2)
        XCTAssertEqual(store.audit.filter { $0.id == command }.count, 1)
        let plan = try XCTUnwrap(store.plan(id))
        XCTAssertEqual(store.status(of: plan), .draft)
        XCTAssertTrue(plan.workouts.isEmpty)
        XCTAssertNil(store.createPlan(PlanDraft(title: "  ")))
    }

    @MainActor
    func testCloneCopiesWorkoutsWithNewIdentityAndNoActivations() throws {
        let store = try makeStore()
        let source = store.starterPlan
        let id = try XCTUnwrap(store.createPlan(PlanDraft(method: .clone(source.lineageId), title: "Bản sao")))
        let copy = try XCTUnwrap(store.plan(id))
        XCTAssertEqual(copy.workouts.map(\.title), source.workouts.map(\.title))
        XCTAssertTrue(Set(copy.workouts.map(\.id)).isDisjoint(with: source.workouts.map(\.id)))
        XCTAssertTrue(copy.activations.isEmpty)
        XCTAssertEqual(store.audit.first?.action, "Nhân bản giáo án")
    }

    @MainActor
    func testEventPlanNeedsAnEventDayFromToday() throws {
        let store = try makeStore()
        XCTAssertNil(store.createPlan(PlanDraft(title: "Giải", kind: .event)))
        XCTAssertNil(store.createPlan(PlanDraft(title: "Giải", kind: .event, eventDate: store.today().adding(days: -1))))
        let id = try XCTUnwrap(store.createPlan(PlanDraft(title: "Giải", kind: .event, eventName: "10 km", eventDate: store.today().adding(days: 30))))
        XCTAssertEqual(store.daysUntilEvent(try XCTUnwrap(store.plan(id))), 30)
    }

    @MainActor
    func testStartNeedsWorkoutsAndADayFromToday() throws {
        let store = try makeStore()
        let blank = try XCTUnwrap(store.createPlan(PlanDraft(title: "Trống")))
        XCTAssertFalse(store.startPlan(blank, from: store.today()))
        let plan = try template(store, "Mẫu")
        XCTAssertFalse(store.startPlan(plan, from: store.today().adding(days: -1)))
        XCTAssertTrue(store.startPlan(plan, from: store.today().adding(days: 3)))
        XCTAssertEqual(store.status(of: try XCTUnwrap(store.plan(plan))), .scheduled)
    }

    @MainActor
    func testFourthPlanIsRefusedUnlessAnotherIsPausedInTheSameCommand() throws {
        let store = try makeStore()
        let today = store.today()
        let second = try template(store, "Hai")
        let third = try template(store, "Ba")
        let fourth = try template(store, "Bốn")
        XCTAssertTrue(store.startPlan(second, from: today))
        XCTAssertTrue(store.startPlan(third, from: today.adding(days: 7)))
        XCTAssertEqual(store.followedPlans().count, 3)

        XCTAssertFalse(store.startPlan(fourth, from: today))
        XCTAssertNotNil(store.alertMessage)
        // The plan starting next week counts too: from then on four plans would be followed.
        XCTAssertEqual(Set(store.limitConflicts(starting: fourth, from: today).map(\.lineageId)), [store.starterPlan.lineageId, second, third])

        let starter = store.starterPlan.lineageId
        let command = UUID()
        XCTAssertTrue(store.startPlan(fourth, from: today, resolving: LimitResolution(lineageId: starter, action: .pause), commandId: command))
        XCTAssertTrue(store.startPlan(fourth, from: today, resolving: LimitResolution(lineageId: starter, action: .pause), commandId: command))
        XCTAssertEqual(store.status(of: store.starterPlan), .paused)
        XCTAssertEqual(store.status(of: try XCTUnwrap(store.plan(second))), .active)
        XCTAssertEqual(store.followedPlans().count, 3)
        XCTAssertEqual(store.plan(fourth)?.activations.count, 1)
        XCTAssertEqual(store.audit.filter { $0.id == command }.count, 1)
    }

    /// Pausing on the start day itself cancels that start (an activation cannot end before it begins).
    @MainActor
    func testPausingOnTheStartDayCancelsTheStart() throws {
        let store = try makeStore()
        let id = try template(store, "Mới")
        XCTAssertTrue(store.startPlan(id, from: store.today()))
        XCTAssertTrue(store.pausePlan(id))
        XCTAssertTrue(try XCTUnwrap(store.plan(id)).activations.isEmpty)
        XCTAssertEqual(store.status(of: try XCTUnwrap(store.plan(id))), .draft)
    }

    @MainActor
    func testPauseResumeKeepsOneActivationPerPeriodAndNoOverlap() throws {
        let database = try AppDatabase.inMemory()
        let store = try makeStore(database)
        let id = store.starterPlan.lineageId
        XCTAssertTrue(store.pausePlan(id))
        XCTAssertEqual(store.status(of: store.starterPlan), .paused)
        XCTAssertEqual(store.starterPlan.activations.first?.toDate, store.today().adding(days: -1))
        XCTAssertFalse(store.pausePlan(id))
        XCTAssertTrue(store.startPlan(id, from: store.today()))
        XCTAssertEqual(store.status(of: store.starterPlan), .active)
        XCTAssertTrue(PlanLifecycle.overlappingActivations(store.starterPlan.activations).isEmpty)

        let relaunched = AppStore(database: database)
        XCTAssertEqual(relaunched.starterPlan.activations, store.starterPlan.activations)
    }

    @MainActor
    func testEndRecordsReasonAndNoteAndMakesThePlanReadOnly() throws {
        let store = try makeStore()
        let id = store.starterPlan.lineageId
        XCTAssertFalse(store.endPlan(id, reason: .completed, note: String(repeating: "a", count: 501)))
        XCTAssertTrue(store.endPlan(id, reason: .completed, note: "Xong"))
        XCTAssertEqual(store.status(of: store.starterPlan), .ended)
        XCTAssertEqual(store.starterPlan.endReason, .completed)
        XCTAssertEqual(store.starterPlan.endNote, "Xong")
        XCTAssertFalse(store.isEditable(store.starterPlan))
        XCTAssertFalse(store.renamePlan(id, title: "Khác"))
        var workout = store.starterPlan.workouts[0]
        workout.title = "Sửa"
        XCTAssertFalse(store.updateWorkout(workout, in: id))
        XCTAssertTrue(store.scheduledItems(on: store.today()).isEmpty)
    }

    @MainActor
    func testArchiveOnlyWhenNotFollowed() throws {
        let store = try makeStore()
        let id = store.starterPlan.lineageId
        XCTAssertFalse(store.setArchived(id, true))
        XCTAssertTrue(store.pausePlan(id))
        XCTAssertTrue(store.setArchived(id, true))
        XCTAssertEqual(store.status(of: store.starterPlan), .archived)
        XCTAssertTrue(store.setArchived(id, false))
        XCTAssertEqual(store.status(of: store.starterPlan), .paused)
    }

    @MainActor
    func testExtendTurnsAPastEventPlanIntoAWeeklyRevision() throws {
        let store = try makeStore()
        let id = try XCTUnwrap(sampleWorkouts(store, PlanDraft(title: "Giải", kind: .event, eventDate: store.today())))
        XCTAssertFalse(store.extendPlan(id))
        // Simulate the event day passing: a plan followed from earlier with its event yesterday.
        var plan = try XCTUnwrap(store.plan(id))
        plan.eventDate = store.today().adding(days: -1)
        plan.activations = [PlanActivation(id: UUID(), fromDate: store.today().adding(days: -5), timezone: TimeZone.current.identifier)]
        XCTAssertTrue(store.commit(ContentChange(plans: [plan])))
        XCTAssertTrue(store.isFinished(try XCTUnwrap(store.plan(id))))
        XCTAssertTrue(store.scheduledItems(from: store.today(), through: store.today().adding(days: 6)).allSatisfy { $0.plan.lineageId != id })

        XCTAssertTrue(store.extendPlan(id))
        let extended = try XCTUnwrap(store.plan(id))
        XCTAssertEqual(extended.kind, .weekly)
        XCTAssertEqual(extended.revision, plan.revision + 1)
        XCTAssertFalse(store.isFinished(extended))
        XCTAssertFalse(store.scheduledItems(from: store.today(), through: store.today().adding(days: 6)).allSatisfy { $0.plan.lineageId != id })
    }

    @MainActor
    func testScheduleMergesPlansAndCompletedSessionsCountOnlyForTheirPlan() throws {
        let store = try makeStore()
        let today = store.today()
        let second = try template(store, "Hai")
        XCTAssertTrue(store.startPlan(second, from: today))
        let todays = store.scheduledItems(on: today)
        let weekday = today.isoWeekday
        let expected = store.visiblePlans.filter { plan in plan.workouts.contains { $0.weekday == weekday } }.count
        XCTAssertEqual(todays.count, expected)
        guard let first = todays.first else { return }

        store.startWorkout(first.workout)
        let player = try XCTUnwrap(store.player)
        for _ in 0..<100 where player.state.phase != .reviewingSummary {
            if player.state.phase == .resting { player.skipRest() } else { player.skipCurrentSet(reason: "test") }
        }
        player.finish()
        XCTAssertEqual(store.history.first { $0.id == player.state.sessionId }?.status, .completed)
        let after = store.scheduledItems(on: today)
        XCTAssertEqual(after.filter(\.isDone).map(\.plan.lineageId), [first.plan.lineageId])
    }
}

extension AppStore {
    /// The bundled starter plan seeded on first launch.
    var starterPlan: WorkoutPlan { plans[0] }

    func renameStarterPlan(_ title: String) -> Bool { renamePlan(starterPlan.lineageId, title: title) }

    func deleteStarterPlan() -> Bool { deletePlan(starterPlan.lineageId) }
}
