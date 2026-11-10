import CaliCore
import CaliDomain
import CaliDomainTestSupport
import Foundation
import GRDB
import XCTest

/// IOS-001: content tables (schema v2_content) and the shared single writer.
final class ContentStoreTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testMigratingAV1DatabaseKeepsTheActiveSessionAndAddsAnEmptyTitle() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        do {
            let pool = try DatabasePool(path: dir.dbURL.path, configuration: CaliDatabase.configuration())
            try CaliDatabase.migrator.migrate(pool, upTo: "v1")
            // A v1-era row (no title column), with a real state document.
            let scratch = try CoreFixture.inMemory()
            try scratch.send(scratch.create())
            let json = String(decoding: try DomainJSON.makeEncoder().encode(scratch.state), as: UTF8.self)
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO local_session_state (session_id, status, phase, revision, state_json, updated_at)
                    VALUES (?, 'active', 'ready', 1, ?, '2026-11-07T08:00:00.000Z')
                    """, arguments: [sessionA.uuidString.lowercased(), json])
            }
        }
        let pool = try CaliDatabase.openPool(at: dir.dbURL)
        let f = CoreFixture(writer: pool)
        XCTAssertEqual(f.state.sessionId, sessionA)
        XCTAssertEqual(try f.coordinator.activeSessionTitle(), "")
        XCTAssertFalse(try ContentStore(writer: pool).isInitialized())
    }

    func testSeedIsWrittenOnceAndLoadsBack() throws {
        let db = try CaliDatabase.openInMemory()
        let store = ContentStore(writer: db)
        XCTAssertTrue(try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc))
        XCTAssertFalse(try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc))

        let content = try store.load()
        XCTAssertEqual(content.catalog.map(\.id), Content.catalog.map(\.id), "catalog keeps its order")
        XCTAssertEqual(content.plans.map { $0.stripped() }, [Content.plan()])
        XCTAssertEqual(content.history.map(\.id), [uuid(400)])
        XCTAssertEqual(content.recommendations, [Content.recommendation(500)])
        XCTAssertEqual(content.settings, AppSettings())

        let row = try db.read { try Row.fetchOne($0, sql: "SELECT kind, status, primary_discipline, dirty FROM training_plans") }
        XCTAssertEqual(row?["kind"], "weekly")
        XCTAssertEqual(row?["status"], "current")
        XCTAssertEqual(row?["primary_discipline"], "calisthenics")
        XCTAssertEqual(row?["dirty"], 1)
        let activation = try db.read { try Row.fetchOne($0, sql: "SELECT from_date, to_date, timezone FROM plan_activations") }
        XCTAssertEqual(activation?["from_date"], "2026-11-07")
        XCTAssertNil(activation?["to_date"] as String?)
        XCTAssertEqual(activation?["timezone"], utc.identifier)
    }

    func testSameAuditCommandIdIsAppliedOnce() throws {
        let store = ContentStore(writer: try CaliDatabase.openInMemory())
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        var plan = Content.plan()
        plan.title = "Đổi tên"
        let change = ContentChange(plans: [plan], audit: AuditEntry(id: uuid(900), at: t0, action: "rename_plan", detail: "Đổi tên"))
        XCTAssertEqual(try store.apply(change, now: t0), .applied)

        plan.title = "Lần hai"
        let repeated = ContentChange(plans: [plan], audit: AuditEntry(id: uuid(900), at: t0, action: "rename_plan", detail: "Lần hai"))
        XCTAssertEqual(try store.apply(repeated, now: t0), .duplicate)
        let content = try store.load()
        XCTAssertEqual(content.plans.first?.title, "Đổi tên")
        XCTAssertEqual(content.audit.map(\.id), [uuid(900)])
    }

    func testPlanEditsReplaceWorkoutsAndExercisesExactly() throws {
        let store = ContentStore(writer: try CaliDatabase.openInMemory())
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        var plan = Content.plan()
        plan.workouts[0].exercises.removeFirst()
        plan.workouts[0].exercises[0].setCount = 5
        plan.workouts.append(PlannedWorkout(id: uuid(201), weekday: 3, title: "Thứ 4", focus: "", exercises: [
            PlannedExercise(id: uuid(310), exerciseId: uuid(7003), setCount: 2, target: .load(reps: 5, loadKg: 60), restSeconds: 150),
        ]))
        try store.apply(ContentChange(plans: [plan]), now: t0)
        XCTAssertEqual(try store.load().plans.map { $0.stripped() }, [plan])

        let discipline = try store.writer.read { try String.fetchOne($0, sql: "SELECT primary_discipline FROM training_plans") }
        XCTAssertEqual(discipline, "mixed", "calisthenics + load exercises ⇒ mixed (BR-10)")

        plan.workouts.removeLast()
        try store.apply(ContentChange(plans: [plan]), now: t0)
        XCTAssertEqual(try store.load().plans.map { $0.stripped() }, [plan])
        XCTAssertEqual(try store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM planned_exercises") }, 1, "cascade removed orphans")
    }

    func testInvalidChangeRollsBackEverything() throws {
        let store = ContentStore(writer: try CaliDatabase.openInMemory())
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        var plan = Content.plan()
        plan.title = "Không được lưu"
        plan.workouts[0].exercises[0].exerciseId = uuid(9999) // not in the catalog ⇒ FK failure
        let change = ContentChange(plans: [plan], settings: AppSettings(countdownSeconds: 10),
                                   audit: AuditEntry(id: uuid(901), at: t0, action: "edit", detail: ""))
        XCTAssertThrowsError(try store.apply(change, now: t0))

        let content = try store.load()
        XCTAssertEqual(content.plans.map { $0.stripped() }, [Content.plan()])
        XCTAssertEqual(content.settings.countdownSeconds, 3)
        XCTAssertTrue(content.audit.isEmpty)
    }

    // MARK: IOS-013 multi-plan

    func testClosingAnActivationStoresItsEndReasonAndDeletedPlanKeepsItsWorkouts() throws {
        let store = ContentStore(writer: try CaliDatabase.openInMemory())
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        let later = t0.addingTimeInterval(3 * 86_400)
        var plan = try XCTUnwrap(store.load().plans.first)
        let activation = try XCTUnwrap(plan.activations.first)
        plan.activations[0].toDate = LocalDate("2026-11-10")
        plan.deletedAt = later
        try store.apply(ContentChange(plans: [plan], activationEndReasons: [activation.id: .deleted]), now: later)

        let loaded = try XCTUnwrap(store.load().plans.first)
        XCTAssertNotNil(loaded.deletedAt)
        XCTAssertEqual(loaded.workouts, Content.plan().workouts, "soft delete keeps the workouts so history stays attributable")
        XCTAssertEqual(loaded.activations.map(\.toDate), [LocalDate("2026-11-10")])
        let row = try store.writer.read { try Row.fetchOne($0, sql: "SELECT to_date, end_reason FROM plan_activations") }
        XCTAssertEqual(row?["to_date"], "2026-11-10")
        XCTAssertEqual(row?["end_reason"], "deleted")
    }

    func testAnActivationNoLongerListedIsCancelledNotDeleted() throws {
        let store = ContentStore(writer: try CaliDatabase.openInMemory())
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        var plan = try XCTUnwrap(store.load().plans.first)
        plan.activations = []
        try store.apply(ContentChange(plans: [plan]), now: t0)

        XCTAssertEqual(try store.load().plans.first?.activations, [])
        let row = try store.writer.read { try Row.fetchOne($0, sql: "SELECT deleted_at, dirty FROM plan_activations") }
        XCTAssertNotNil(row?["deleted_at"] as String?, "the tombstone stays for sync")
        XCTAssertEqual(row?["dirty"], 1)
    }

    func testReopeningAClosedActivationClearsItsEndReason() throws {
        let store = ContentStore(writer: try CaliDatabase.openInMemory())
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        var plan = try XCTUnwrap(store.load().plans.first)
        let id = try XCTUnwrap(plan.activations.first?.id)
        plan.activations[0].toDate = LocalDate("2026-11-08")
        try store.apply(ContentChange(plans: [plan], activationEndReasons: [id: .paused]), now: t0)
        plan.activations[0].toDate = nil
        try store.apply(ContentChange(plans: [plan]), now: t0)
        XCTAssertNil(try store.writer.read { try String.fetchOne($0, sql: "SELECT end_reason FROM plan_activations") })
    }

    func testSeveralPlansRoundTripInCreationOrderWithAllLifecycleFields() throws {
        let store = ContentStore(writer: try CaliDatabase.openInMemory())
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        let event = WorkoutPlan(
            id: uuid(110), title: "Chạy 10 km", workouts: [], kind: .event, eventDate: LocalDate("2027-03-14"), eventName: "Giải mùa xuân",
            primaryDiscipline: .running, endedAt: t0, endReason: .stopped, endNote: "Đau gối", archivedAt: t0,
            createdAt: t0.addingTimeInterval(60),
            activations: [PlanActivation(id: uuid(111), fromDate: LocalDate("2026-11-09")!, toDate: LocalDate("2026-11-20"), timezone: "Asia/Ho_Chi_Minh")]
        )
        try store.apply(ContentChange(plans: [event]), now: t0)

        let plans = try store.load().plans
        XCTAssertEqual(plans.map(\.id), [uuid(100), uuid(110)])
        XCTAssertEqual(plans[1], event)
        XCTAssertEqual(plans[1].lineageId, uuid(110), "a root revision is its own lineage")
        XCTAssertEqual(plans[1].status(today: LocalDate("2026-11-10")!), .archived)
    }

    func testHistoryIsAttributedToThePlanEvenAfterTheWorkoutIsRemoved() throws {
        let db = try CaliDatabase.openInMemory()
        let store = ContentStore(writer: db)
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        XCTAssertEqual(try store.load().history.first?.planLineageId, uuid(100), "older rows resolve through planned_workouts")

        // A live session stores the lineage on the row itself (the harness plans workout 6000).
        var plan = try XCTUnwrap(store.load().plans.first)
        plan.workouts[0].id = uuid(6000)
        try store.apply(ContentChange(plans: [plan]), now: t0)
        let f = CoreFixture(writer: db)
        _ = try f.coordinator.handle(f.create([Specs.hold(sets: 1)]), sessionTitle: "Buổi")
        try f.send(f.startSet())
        f.clock.advance(by: 5)
        try f.send(f.stopSet())
        try f.send(f.confirm(holdMs: 5_000))
        try f.send(.finishSession(SimpleCommand(commandId: f.freshId())))
        plan = try XCTUnwrap(store.load().plans.first)
        plan.workouts = []
        try store.apply(ContentChange(plans: [plan]), now: t0)

        let live = try XCTUnwrap(store.load().history.first { $0.id == sessionA })
        XCTAssertEqual(live.planLineageId, uuid(100))
    }

    func testFinishingASessionWritesHistoryInTheSameTransaction() throws {
        let db = try CaliDatabase.openInMemory()
        let store = ContentStore(writer: db)
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        let f = CoreFixture(writer: db)
        _ = try f.coordinator.handle(f.create([Specs.hold(sets: 1)]), sessionTitle: "Thứ 2 · Toàn thân")
        XCTAssertEqual(try f.coordinator.activeSessionTitle(), "Thứ 2 · Toàn thân")
        try f.send(f.startSet())
        f.clock.advance(by: 5)
        try f.send(f.stopSet())
        try f.send(f.confirm(holdMs: 5_000))
        XCTAssertEqual(try store.load().history.count, 1, "not terminal yet: only the sample row")

        let finish = Command.finishSession(SimpleCommand(commandId: f.freshId()))
        try f.send(finish)
        _ = try f.coordinator.handle(finish) // replay must not add a second row

        let history = try store.load().history
        XCTAssertEqual(history.count, 2)
        let live = try XCTUnwrap(history.first { $0.id == sessionA })
        XCTAssertEqual(live.title, "Thứ 2 · Toàn thân")
        XCTAssertEqual(live.status, .completed)
        XCTAssertFalse(live.isSample)
        XCTAssertEqual(live.sets.map(\.holdMs), [5_000])
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT source FROM session_history WHERE id = ?", arguments: [sessionA.uuidString.lowercased()]) }, "live")
    }

    func testAbandoningASessionAlsoWritesHistory() throws {
        let db = try CaliDatabase.openInMemory()
        let f = CoreFixture(writer: db)
        try f.toExercising()
        try f.send(.abandonSession(AbandonSession(commandId: f.freshId(), reason: "test")))
        let history = try ContentStore(writer: db).load().history
        XCTAssertEqual(history.map(\.status), [.abandoned])
    }

    func testResetRestoresTheSeedAndClearsSessions() throws {
        let db = try CaliDatabase.openInMemory()
        let store = ContentStore(writer: db)
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        let f = CoreFixture(writer: db)
        try f.toExercising()
        try store.apply(ContentChange(settings: AppSettings(countdownSeconds: 10), audit: AuditEntry(id: uuid(902), at: t0, action: "s", detail: "")))

        try store.resetAll(to: Content.seed(), now: t0, timeZone: utc)
        let content = try store.load()
        XCTAssertEqual(content.settings, AppSettings())
        XCTAssertTrue(content.audit.isEmpty)
        XCTAssertNil(try f.coordinator.activeState())
        XCTAssertEqual(try f.coordinator.counts().outbox, 0)
    }
}
