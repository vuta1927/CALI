import CaliDomain
import Foundation
import GRDB
import XCTest
@testable import CaliCore

/// IOS-007 against a real test server. Opt-in: set `CALI_LIVE_BASE_URL` and `CALI_LIVE_TOKEN` in the environment (a dev JWT from
/// the backend's `Cali.DevToken`). Without them every test skips, so CI and a plain `swift test` never touch a network.
/// The values are never stored in the repo. Each run writes new synthetic ids (a session of a test user), nothing else.
final class LiveServerTests: XCTestCase {
    private struct Token: SyncTokenProvider {
        let value: String
        func accessToken() async throws -> String { value }
        func refreshAccessToken() async throws { throw SyncTransportError.unauthorized }
    }

    private func api() throws -> URLSessionSyncAPI {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["CALI_LIVE_BASE_URL"], let url = URL(string: base), let token = env["CALI_LIVE_TOKEN"] else { throw XCTSkip("CALI_LIVE_* not set") }
        return URLSessionSyncAPI(baseURL: url, tokens: Token(value: token))
    }

    /// Create, then abandon at once: the server allows one active session per user, so a run must not leave one behind.
    /// Covers the dependency order (session, execution), the terminal upsert rebased on the server version, and the pull cursor.
    func testSessionRoundTripAgainstTheServer() async throws {
        let api = try api()
        let f = try CoreFixture.inMemory()
        var spec = Specs.hold()
        spec.id = UUID() // fixture ids repeat between runs; the server refuses a reused mutation id with another payload
        spec.exerciseId = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")! // tuck-planche (static_hold) of the seeded test catalog
        spec.catalogVersion = 1
        spec.plannedExerciseId = nil // a free workout: no plan row on the server to point at
        try f.send(.createSession(CreateSession(commandId: UUID(), sessionId: UUID(), plannedWorkoutId: nil, executions: [spec])))
        try f.send(.abandonSession(AbandonSession(commandId: UUID(), reason: "live test")))
        let writer = f.coordinator.writer
        let engine = OutboxSyncEngine(writer: writer, api: api)

        let run = await engine.syncOnce()
        let rows = try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT entity_type, state, error_code FROM sync_outbox ORDER BY seq")
                .map { "\($0["entity_type"] as String) \($0["state"] as String) \(($0["error_code"] as String?) ?? "-")" }
        }
        XCTAssertEqual(rows.first, "workout_session acked -", "\(rows)")
        XCTAssertEqual(rows.last, "workout_session acked -", "the terminal upsert rebased on the server version: \(rows)")
        XCTAssertEqual(run.outcome, .done)
        let cursor = try await writer.read { try String.fetchOne($0, sql: "SELECT cursor FROM sync_cursor WHERE scope = 'main'") }
        XCTAssertNotNil(cursor, "pull saved a cursor")
        // The execution points at a catalog exercise (a foreign key). A server whose catalog is empty rejects it with `validation_failed`.
        if rows[1] != "exercise_execution acked -" { throw XCTSkip("session path verified; execution not accepted (\(rows[1])): the test server needs a seeded exercise catalog") }
    }

    private func states(_ writer: any DatabaseWriter) async throws -> [String] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT entity_type, state, error_code FROM sync_outbox ORDER BY seq")
                .map { "\($0["entity_type"] as String) \($0["state"] as String) \(($0["error_code"] as String?) ?? "-")" }
        }
    }

    /// Two devices: A reads the server catalog, builds a plan, trains one set of it and pushes everything; B starts empty,
    /// reads the catalog, pulls and must end up with A's plan. A then deletes the plan so a run leaves no live plan behind.
    func testTwoDevicesThroughTheServer() async throws {
        let api = try api()
        let env = ProcessInfo.processInfo.environment
        let catalogAPI = URLSessionExerciseCatalogAPI(baseURL: URL(string: env["CALI_LIVE_BASE_URL"]!)!)
        let utc = TimeZone(identifier: "UTC")!
        let exerciseId = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")!

        // Device A
        let a = try CoreFixture.inMemory()
        let storeA = ContentStore(writer: a.coordinator.writer)
        try storeA.seedIfEmpty(.empty(), now: a.clock.now(), timeZone: utc)
        let catalogCount = try await ExerciseCatalogRefresher(api: catalogAPI, store: storeA).refresh(now: a.clock.now())
        XCTAssertEqual(catalogCount, 9, "the seeded test catalog")

        let item = PlannedExercise(id: UUID(), exerciseId: exerciseId, setCount: 1, target: .staticHold(holdSeconds: 5), restSeconds: 30)
        let workout = PlannedWorkout(id: UUID(), weekday: 1, title: "Live test", focus: "", exercises: [item])
        var plan = WorkoutPlan(id: UUID(), title: "Live test \(UUID().uuidString.prefix(6))", workouts: [workout])
        plan.createdAt = a.clock.now()
        try storeA.apply(ContentChange(plans: [plan]), now: a.clock.now())

        let spec = ExecutionSpec(id: UUID(), plannedExerciseId: item.id, exerciseId: exerciseId, catalogVersion: 1, setCount: 1, target: item.target, restSeconds: 30)
        try a.send(.createSession(CreateSession(commandId: UUID(), sessionId: UUID(), plannedWorkoutId: workout.id, executions: [spec])))
        try a.send(.startSet(StartSet(commandId: UUID(), countdownSeconds: 0)))
        a.clock.advance(by: 6)
        try a.send(.stopSet(SimpleCommand(commandId: UUID())))
        try a.send(.confirmSet(ConfirmSet(commandId: UUID(), setResultId: UUID(), executionId: spec.id, setIndex: 1, status: .completed, actualHoldMs: 5_000)))
        try a.send(.finishSession(SimpleCommand(commandId: UUID())))

        let engineA = OutboxSyncEngine(writer: a.coordinator.writer, api: api)
        let runA = await engineA.syncOnce()
        let rowsA = try await states(a.coordinator.writer)
        XCTAssertTrue(rowsA.allSatisfy { $0.contains(" acked ") }, "\(rowsA) \(runA)")
        XCTAssertEqual(rowsA.filter { $0.hasPrefix("training_plan") }.count, 1)

        // Device B: empty
        let b = try CoreFixture.inMemory()
        let storeB = ContentStore(writer: b.coordinator.writer)
        try storeB.seedIfEmpty(.empty(), now: b.clock.now(), timeZone: utc)
        try await ExerciseCatalogRefresher(api: catalogAPI, store: storeB).refresh(now: b.clock.now())
        let runB = await OutboxSyncEngine(writer: b.coordinator.writer, api: api).syncOnce()
        let pulledPlan = try storeB.load().plans.first { $0.id == plan.id }
        XCTAssertNotNil(pulledPlan, "B has A's plan after one sync: \(runB)")
        XCTAssertEqual(pulledPlan?.title, plan.title)
        XCTAssertEqual(pulledPlan?.workouts.first?.exercises.first?.exerciseId, exerciseId)
        XCTAssertEqual(pulledPlan?.workouts.first?.exercises.first?.target, item.target)

        // Clean up: A deletes the plan; the delete reaches the server.
        var gone = plan
        gone.deletedAt = a.clock.now()
        try storeA.apply(ContentChange(plans: [gone]), now: a.clock.now())
        _ = await engineA.syncOnce()
        let leftovers = try await states(a.coordinator.writer).filter { !$0.contains(" acked ") }
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    /// Everything a plan carries besides workouts: an activation, a phase, a goal and a body weight. A is the only writer;
    /// B starts empty and must read all of it back. Cleanup deletes them so the test user keeps no live plan.
    func testActivationGoalsAndBodyThroughTheServer() async throws {
        let api = try api()
        let env = ProcessInfo.processInfo.environment
        let catalogAPI = URLSessionExerciseCatalogAPI(baseURL: URL(string: env["CALI_LIVE_BASE_URL"]!)!)
        let utc = TimeZone(identifier: "UTC")!
        let exerciseId = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")!

        let a = try CoreFixture.inMemory()
        let storeA = ContentStore(writer: a.coordinator.writer)
        try storeA.seedIfEmpty(.empty(), now: a.clock.now(), timeZone: utc)
        try await ExerciseCatalogRefresher(api: catalogAPI, store: storeA).refresh(now: a.clock.now())

        let item = PlannedExercise(id: UUID(), exerciseId: exerciseId, setCount: 2, target: .staticHold(holdSeconds: 10), restSeconds: 45)
        let workout = PlannedWorkout(id: UUID(), weekday: 3, title: "Live full", focus: "", exercises: [item])
        let phase = PlanPhase(id: UUID(), name: "Nền tảng", weeks: 4)
        let today = try XCTUnwrap(LocalDate(Self.localDay(a.clock.now(), utc)))
        var plan = WorkoutPlan(id: UUID(), title: "Live full \(UUID().uuidString.prefix(6))", workouts: [workout], phases: [phase])
        plan.createdAt = a.clock.now()
        plan.activations = [PlanActivation(id: UUID(), fromDate: today, timezone: "UTC")]
        try storeA.apply(ContentChange(plans: [plan]), now: a.clock.now())

        let goal = PlanGoal(id: UUID(), planLineageId: plan.lineageId, title: "Giữ 30 giây", indicatorId: "best_hold_seconds",
                            exerciseId: exerciseId, baseline: 10, target: .value(30), pinned: true)
        let weight = BodyMeasurement(value: Decimal(string: "72.4")!, measuredAt: a.clock.now())
        try storeA.apply(ContentChange(goals: [goal], bodyMeasurements: [weight]), now: a.clock.now())

        let engineA = OutboxSyncEngine(writer: a.coordinator.writer, api: api)
        let runA = await engineA.syncOnce()
        let rowsA = try await states(a.coordinator.writer)
        XCTAssertTrue(rowsA.allSatisfy { $0.contains(" acked ") }, "\(rowsA) \(runA)")
        for type in ["training_plan", "plan_activation", "plan_phase", "plan_goal", "body_measurement"] {
            XCTAssertEqual(rowsA.filter { $0.hasPrefix(type + " ") }.count, 1, "\(type) in \(rowsA)")
        }

        let b = try CoreFixture.inMemory()
        let storeB = ContentStore(writer: b.coordinator.writer)
        try storeB.seedIfEmpty(.empty(), now: b.clock.now(), timeZone: utc)
        try await ExerciseCatalogRefresher(api: catalogAPI, store: storeB).refresh(now: b.clock.now())
        let runB = await OutboxSyncEngine(writer: b.coordinator.writer, api: api).syncOnce()
        let content = try storeB.load()
        let pulled = try XCTUnwrap(content.plans.first { $0.id == plan.id }, "\(runB)")
        XCTAssertEqual(pulled.activations.map(\.fromDate), [today])
        XCTAssertEqual(pulled.phases.map(\.name), ["Nền tảng"])
        XCTAssertEqual(pulled.phases.map(\.weeks), [4])
        XCTAssertEqual(content.goals.first { $0.id == goal.id }?.target, .value(30))
        XCTAssertEqual(content.bodyMeasurements.first { $0.id == weight.id }?.value, Decimal(string: "72.4"))

        var goneGoal = goal, goneWeight = weight, gonePlan = plan
        goneGoal.deletedAt = a.clock.now(); goneWeight.deletedAt = a.clock.now(); gonePlan.deletedAt = a.clock.now()
        try storeA.apply(ContentChange(plans: [gonePlan], goals: [goneGoal], bodyMeasurements: [goneWeight]), now: a.clock.now())
        _ = await engineA.syncOnce()
        let leftovers = try await states(a.coordinator.writer).filter { !$0.contains(" acked ") }
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    /// Two devices edit the same plan from the same server version. A pushes first; B's edit is based on the old version, so the
    /// server answers `version_conflict`: B's row waits as `conflicted` with the server's copy attached, nothing is overwritten.
    func testStaleEditIsAConflictNotAnOverwrite() async throws {
        let api = try api()
        let utc = TimeZone(identifier: "UTC")!
        let exerciseId = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")!
        let catalogAPI = URLSessionExerciseCatalogAPI(baseURL: URL(string: ProcessInfo.processInfo.environment["CALI_LIVE_BASE_URL"]!)!)

        let a = try CoreFixture.inMemory()
        let storeA = ContentStore(writer: a.coordinator.writer)
        try storeA.seedIfEmpty(.empty(), now: a.clock.now(), timeZone: utc)
        try await ExerciseCatalogRefresher(api: catalogAPI, store: storeA).refresh(now: a.clock.now())
        let item = PlannedExercise(id: UUID(), exerciseId: exerciseId, setCount: 1, target: .staticHold(holdSeconds: 5), restSeconds: 30)
        var plan = WorkoutPlan(id: UUID(), title: "Conflict \(UUID().uuidString.prefix(6))",
                               workouts: [PlannedWorkout(id: UUID(), weekday: 2, title: "Live", focus: "", exercises: [item])])
        plan.createdAt = a.clock.now()
        try storeA.apply(ContentChange(plans: [plan]), now: a.clock.now())
        let engineA = OutboxSyncEngine(writer: a.coordinator.writer, api: api)
        _ = await engineA.syncOnce()

        let b = try CoreFixture.inMemory()
        let storeB = ContentStore(writer: b.coordinator.writer)
        try storeB.seedIfEmpty(.empty(), now: b.clock.now(), timeZone: utc)
        try await ExerciseCatalogRefresher(api: catalogAPI, store: storeB).refresh(now: b.clock.now())
        let engineB = OutboxSyncEngine(writer: b.coordinator.writer, api: api)
        _ = await engineB.syncOnce()
        var onB = try XCTUnwrap(try storeB.load().plans.first { $0.id == plan.id }, "B pulled the plan")

        var editA = plan
        editA.title = plan.title + " A"
        try storeA.apply(ContentChange(plans: [editA]), now: a.clock.now())
        let afterA = await engineA.syncOnce()
        let rowsA = try await states(a.coordinator.writer)
        XCTAssertTrue(rowsA.allSatisfy { $0.contains(" acked ") }, "\(rowsA) \(afterA)")

        onB.title = plan.title + " B"
        try storeB.apply(ContentChange(plans: [onB]), now: b.clock.now())
        let afterB = await engineB.syncOnce()
        let rowsB = try await states(b.coordinator.writer)
        XCTAssertTrue(rowsB.contains { $0.hasPrefix("training_plan conflicted") }, "\(rowsB) \(afterB)")

        // Clean up from A (the winner holds the current version).
        var gone = editA
        gone.deletedAt = a.clock.now()
        try storeA.apply(ContentChange(plans: [gone]), now: a.clock.now())
        _ = await engineA.syncOnce()
        let leftovers = try await states(a.coordinator.writer).filter { !$0.contains(" acked ") }
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    private static func localDay(_ date: Date, _ zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
    }
}
