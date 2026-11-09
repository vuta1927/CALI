import CaliCore
import CaliDomain
import XCTest
@testable import CaliApp

/// IOS-014: running set results (km + h:mm:ss, pace derived) and the race result of an event plan.
final class RunningResultTests: XCTestCase {
    @MainActor
    private func makeStore() throws -> AppStore {
        let store = AppStore(now: Date().addingTimeInterval(-10 * 86_400), database: try AppDatabase.inMemory())
        store.updateSettings { $0.notificationsEnabled = false; $0.liveActivityEnabled = false; $0.countdownSeconds = 0 }
        return store
    }

    private func run(_ meters: Int, goal: Int? = nil) -> PlannedExercise {
        PlannedExercise(id: UUID(), exerciseId: MockData.easyRun, setCount: 1,
                        target: .distance(distanceMeters: meters, durationSeconds: goal), restSeconds: 0)
    }

    func testRunEntryParsesKmWithCommaOrPointAndTimeParts() {
        XCTAssertEqual(RunEntry(km: "8,25").distanceMeters, 8_250)
        XCTAssertEqual(RunEntry(km: "8.25").distanceMeters, 8_250)
        XCTAssertEqual(RunEntry(km: "0,0005").distanceMeters, 1)
        XCTAssertNil(RunEntry(km: "").distanceMeters)
        XCTAssertNil(RunEntry(km: "abc").distanceMeters)

        XCTAssertEqual(RunEntry(hours: "1", minutes: "2", seconds: "3").durationSeconds, 3_723)
        XCTAssertEqual(RunEntry(minutes: "42").durationSeconds, 2_520)
        XCTAssertNil(RunEntry().durationSeconds)
        XCTAssertNil(RunEntry(minutes: "60").durationSeconds)
        XCTAssertTrue(RunEntry(minutes: "60").hasInvalidTime)
        XCTAssertEqual(RunEntry(hours: "25").durationSeconds, 90_000, "over 24 h is left for the domain to refuse")

        XCTAssertEqual(RunEntry(km: "10", minutes: "49", seconds: "10").paceText, "4:55/km")
        XCTAssertEqual(RunEntry(km: "10", hours: "25").paceText, "Thời gian tối đa 24 giờ")
        XCTAssertEqual(RunEntry(km: "10").paceText, "Nhập quãng đường và thời gian")
        XCTAssertEqual(RunEntry(km: "0", minutes: "5").paceText, "Nhập quãng đường")

        let prefilled = RunEntry(distanceMeters: 5_000, durationSeconds: 3_725)
        XCTAssertEqual(prefilled.km, "5")
        XCTAssertEqual([prefilled.hours, prefilled.minutes, prefilled.seconds], ["1", "2", "5"])
        XCTAssertEqual(RunEntry(distanceMeters: 8_250).km, "8,25")
    }

    @MainActor
    func testRunningSetIsSavedOnlyWithValidKmAndTimeAndShowsPace() throws {
        let store = try makeStore()
        store.startWorkout(PlannedWorkout(id: UUID(), weekday: 1, title: "Chạy", focus: "", exercises: [run(5_000)]))
        let player = try XCTUnwrap(store.player)
        player.startSet()
        player.stopSet()
        XCTAssertEqual(player.state.phase, .awaitingResult)

        player.confirm(status: .completed, reps: nil, holdMs: nil, workMs: nil, rpe: nil, note: nil, distanceMeters: 5_000, durationSeconds: 0)
        XCTAssertEqual(player.state.phase, .awaitingResult, "a completed distance set needs time > 0")
        player.confirm(status: .completed, reps: nil, holdMs: nil, workMs: nil, rpe: nil, note: nil, distanceMeters: 5_000, durationSeconds: 86_401)
        XCTAssertEqual(player.state.phase, .awaitingResult, "over 24 h is refused")

        player.confirm(status: .completed, reps: nil, holdMs: nil, workMs: nil, rpe: nil, note: nil, distanceMeters: 5_000, durationSeconds: 1_530)
        XCTAssertNotEqual(player.state.phase, .awaitingResult)
        if player.state.phase == .resting { player.skipRest() }
        player.finish()

        let set = try XCTUnwrap(store.history.first { $0.id == player.state.sessionId }?.sets.first)
        XCTAssertEqual(set.distanceMeters, 5_000)
        XCTAssertEqual(set.durationSeconds, 1_530)
        XCTAssertEqual(Fmt.actual(set), "5 km 25:30 · 5:06/km")
    }

    @MainActor
    private func eventPlan(_ store: AppStore, eventIn days: Int) throws -> (UUID, PlannedWorkout) {
        let today = store.today()
        let eventDay = today.adding(days: days)
        let id = try XCTUnwrap(store.createPlan(PlanDraft(title: "10 km", kind: .event, eventName: "Giải 10 km", eventDate: eventDay)))
        let race = PlannedWorkout(id: UUID(), weekday: eventDay.isoWeekday, title: "Ngày thi", focus: "", exercises: [run(10_000, goal: 3_000)])
        XCTAssertTrue(store.updateWorkout(race, in: id))
        XCTAssertTrue(store.startPlan(id, from: today))
        return (id, race)
    }

    @MainActor
    func testRaceResultIsOneCompletedManualSessionLinkedToTheEventDayAndIdempotent() throws {
        let store = try makeStore()
        let (id, race) = try eventPlan(store, eventIn: 0)
        let plan = try XCTUnwrap(store.plan(id))
        XCTAssertTrue(store.canRecordRaceResult(plan))
        XCTAssertEqual(store.raceWorkout(of: plan)?.workout.id, race.id)
        let historyBefore = store.history.count

        XCTAssertFalse(store.recordRaceResult(id, distanceMeters: 10_000, durationSeconds: 0))
        XCTAssertFalse(store.recordRaceResult(id, distanceMeters: 10_000, durationSeconds: 86_401))
        XCTAssertFalse(store.recordRaceResult(id, distanceMeters: 0, durationSeconds: 2_950))
        XCTAssertEqual(store.history.count, historyBefore)

        let command = UUID()
        XCTAssertTrue(store.recordRaceResult(id, distanceMeters: 10_000, durationSeconds: 2_950, commandId: command))
        XCTAssertTrue(store.recordRaceResult(id, distanceMeters: 10_000, durationSeconds: 2_950, commandId: command))
        XCTAssertEqual(store.history.count, historyBefore + 1)
        XCTAssertEqual(store.audit.filter { $0.id == command }.count, 1)
        XCTAssertNil(store.player, "no workout is left open")

        let session = try XCTUnwrap(store.raceResults(of: plan).first)
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.plannedWorkoutId, race.id)
        XCTAssertEqual(session.planLineageId, id)
        XCTAssertEqual(session.sets.first?.distanceMeters, 10_000)
        XCTAssertEqual(session.sets.first?.pace?.formatted, "4:55/km")
        XCTAssertEqual(store.status(of: try XCTUnwrap(store.plan(id))), .active, "the plan is not ended for the user")
    }

    @MainActor
    func testRaceResultIsRefusedBeforeTheEventDay() throws {
        let store = try makeStore()
        let (id, _) = try eventPlan(store, eventIn: 3)
        XCTAssertFalse(store.canRecordRaceResult(try XCTUnwrap(store.plan(id))))
        XCTAssertFalse(store.recordRaceResult(id, distanceMeters: 10_000, durationSeconds: 2_950))
        XCTAssertTrue(store.raceResults(of: try XCTUnwrap(store.plan(id))).isEmpty)
    }

    /// Installs from before IOS-014 get the bundled running exercises without losing their edits.
    @MainActor
    func testBundledRunningExercisesReachAnExistingDatabase() throws {
        let database = try AppDatabase.inMemory()
        let first = AppStore(database: database)
        var edited = try XCTUnwrap(first.catalog.first)
        edited.name = "Tên riêng"
        XCTAssertTrue(first.saveExercise(edited))
        let relaunched = AppStore(database: database)
        XCTAssertEqual(relaunched.exercise(edited.id)?.name, "Tên riêng")
        XCTAssertEqual(relaunched.exercise(MockData.easyRun)?.type, .distance)
        XCTAssertEqual(relaunched.exercise(MockData.timedRun)?.type, .duration)
    }
}
