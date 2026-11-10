import CaliCore
import CaliDomain
import XCTest
@testable import CaliApp

/// IOS-004h: the player on top of CaliCore. docs/12 T-01, T-03, T-04, T-06, rest +30 s, abandon, and the
/// docs/14 budget "confirm-set local write < 100 ms p95" measured on a real on-disk database.
final class PlayerHardeningTests: XCTestCase {
    private func plank(sets: Int, hold: Int = 12, rest: Int = 90) -> PlannedWorkout {
        PlannedWorkout(id: UUID(), weekday: 1, title: "Planche", focus: "",
                       exercises: [PlannedExercise(id: UUID(), exerciseId: MockData.tuckPlanche, setCount: sets, target: .staticHold(holdSeconds: hold), restSeconds: rest)])
    }

    @MainActor
    private func makeStore(_ database: AppDatabase) -> AppStore {
        let store = AppStore(database: database)
        store.updateSettings { $0.notificationsEnabled = false; $0.liveActivityEnabled = false; $0.countdownSeconds = 0 }
        return store
    }

    @MainActor
    private func doSet(_ player: WorkoutPlayerModel, holdMs: Int64 = 12_000) {
        player.startSet()
        player.stopSet()
        player.confirm(status: .completed, reps: nil, holdMs: holdMs, workMs: nil, rpe: nil, note: nil)
    }

    private func setResultMutations(_ database: AppDatabase) throws -> Int {
        try database.coordinator.outboxEntries().filter { $0.entityType == "set_result" }.count
    }

    /// T-01: the sample exercise opens with its identity picture, the target and four sets, with no network.
    @MainActor
    func testT01StartShowsPosterTargetAndFourSets() throws {
        let store = makeStore(try AppDatabase.inMemory())
        store.startWorkout(plank(sets: 4))
        let player = try XCTUnwrap(store.player)
        let exercise = try XCTUnwrap(player.currentExercise)
        XCTAssertEqual(exercise.id, MockData.tuckPlanche)
        XCTAssertFalse(exercise.symbol.isEmpty, "visual-first: there is always a poster, even as a placeholder")
        XCTAssertEqual(player.currentExecution?.setCount, 4)
        XCTAssertEqual(player.currentExecution?.target, .staticHold(holdSeconds: 12))
        XCTAssertEqual(player.state.phase, .ready)
    }

    /// T-03 / ADR-009: when the hold target passes the set waits for the user; nothing is recorded as done.
    @MainActor
    func testT03TargetReachedNeverCompletesTheSet() async throws {
        let database = try AppDatabase.inMemory()
        let store = makeStore(database)
        store.startWorkout(plank(sets: 2, hold: 1))
        let player = try XCTUnwrap(store.player)
        player.startSet()
        XCTAssertEqual(player.state.phase, .exercising)
        try await Task.sleep(for: .milliseconds(1_300))
        player.tick()
        XCTAssertEqual(player.state.phase, .awaitingResult, "the app asks, it does not decide")
        XCTAssertTrue(player.records.isEmpty)
        XCTAssertEqual(try database.coordinator.counts().setResults, 0)
        XCTAssertEqual(try setResultMutations(database), 0)

        player.confirm(status: .failed, reps: nil, holdMs: 700, workMs: nil, rpe: nil, note: nil)
        XCTAssertEqual(player.records.first?.status, .failed, "the user's answer is what is stored")
    }

    /// T-04: a double tap on Lưu leaves one result and one sync mutation.
    @MainActor
    func testT04DoubleTapConfirmWritesOneResultAndOneMutation() throws {
        let database = try AppDatabase.inMemory()
        let store = makeStore(database)
        store.startWorkout(plank(sets: 2))
        let player = try XCTUnwrap(store.player)
        player.startSet()
        player.stopSet()
        player.confirm(status: .completed, reps: nil, holdMs: 12_000, workMs: nil, rpe: nil, note: nil)
        player.confirm(status: .completed, reps: nil, holdMs: 12_000, workMs: nil, rpe: nil, note: nil)
        XCTAssertEqual(player.records.count, 1)
        XCTAssertEqual(try database.coordinator.counts().setResults, 1)
        XCTAssertEqual(try setResultMutations(database), 1)
    }

    /// T-06: a whole workout with no network: every result is stored locally and queued for sync.
    @MainActor
    func testT06FullWorkoutIsLocalAndQueuedForSync() throws {
        let database = try AppDatabase.inMemory()
        let store = makeStore(database)
        let samples = store.history.count
        store.startWorkout(plank(sets: 3, rest: 30))
        let player = try XCTUnwrap(store.player)
        for set in 1...3 {
            doSet(player)
            if set < 3 { player.skipRest() }
        }
        XCTAssertEqual(player.state.phase, .reviewingSummary)
        player.finish()
        XCTAssertFalse(store.activeSessionInProgress)
        XCTAssertEqual(store.history.count, samples + 1)
        XCTAssertEqual(store.history.first?.status, .completed)
        XCTAssertEqual(try database.coordinator.counts().setResults, 3)
        XCTAssertEqual(try setResultMutations(database), 3)
        let queued = try database.coordinator.outboxEntries()
        XCTAssertTrue(queued.allSatisfy { $0.state == "pending" }, "queued, nothing was sent")
        let sessionRows = queued.filter { $0.entityType == "workout_session" }
        XCTAssertEqual(sessionRows.count, 2, "one mutation when it started, one terminal mutation when it finished")
        XCTAssertEqual(Set(sessionRows.map(\.entityId)).count, 1)
    }

    /// Rest +30 s moves the rest deadline by exactly 30 s.
    @MainActor
    func testExtendRestAddsThirtySeconds() throws {
        let store = makeStore(try AppDatabase.inMemory())
        store.startWorkout(plank(sets: 2))
        let player = try XCTUnwrap(store.player)
        doSet(player)
        XCTAssertEqual(player.state.phase, .resting)
        let before = try XCTUnwrap(player.state.phaseDeadlineAt)
        player.extendRest()
        let after = try XCTUnwrap(player.state.phaseDeadlineAt)
        XCTAssertEqual(after.timeIntervalSince(before), 30, accuracy: 0.001)
    }

    /// Abandon keeps the sets already confirmed and frees the player for a new workout.
    @MainActor
    func testAbandonKeepsConfirmedSetsAndAllowsANewWorkout() throws {
        let database = try AppDatabase.inMemory()
        let store = makeStore(database)
        store.startWorkout(plank(sets: 3))
        let player = try XCTUnwrap(store.player)
        doSet(player)
        player.abandon(reason: "đau vai")
        XCTAssertEqual(store.history.first { $0.id == player.state.sessionId }?.status, .abandoned)
        XCTAssertEqual(try database.coordinator.counts().setResults, 1, "the confirmed set survives")
        XCTAssertFalse(store.activeSessionInProgress)
        store.startWorkout(plank(sets: 1))
        XCTAssertTrue(store.activeSessionInProgress)
    }

    /// docs/14: confirm-set local write < 100 ms p95. Measured on an on-disk database (WAL), the way the app runs.
    @MainActor
    func testConfirmSetLocalWriteMeetsTheP95Budget() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ios004h-\(UUID().uuidString)/cali.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = AppDatabase(coordinator: WorkoutCoordinator(writer: try CaliDatabase.openPool(at: url, label: "IOS-004h")))
        let store = makeStore(database)
        let sets = 60 // the contract allows at most 20 sets per exercise, so three exercises
        let item = { PlannedExercise(id: UUID(), exerciseId: MockData.tuckPlanche, setCount: 20, target: .staticHold(holdSeconds: 12), restSeconds: 30) }
        store.startWorkout(PlannedWorkout(id: UUID(), weekday: 1, title: "Planche", focus: "", exercises: [item(), item(), item()]))
        let player = try XCTUnwrap(store.player)
        var millis: [Double] = []
        for _ in 1...sets {
            player.startSet()
            player.stopSet()
            let start = MonotonicClock.nowNanos()
            player.confirm(status: .completed, reps: nil, holdMs: 12_000, workMs: nil, rpe: nil, note: nil)
            millis.append(MonotonicClock.seconds(from: start, to: MonotonicClock.nowNanos()) * 1_000)
            if player.state.phase == .resting { player.skipRest() }
        }
        XCTAssertEqual(player.records.count, sets)
        let sorted = millis.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print("IOS-004h confirm-set p50=\(String(format: "%.1f", sorted[sorted.count / 2])) ms p95=\(String(format: "%.1f", p95)) ms max=\(String(format: "%.1f", sorted.last ?? 0)) ms over \(sets) sets")
        XCTAssertLessThan(p95, 100, "docs/14: confirm-set local write < 100 ms p95")
    }
}
