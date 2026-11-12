import CaliDomain
import CaliDomainTestSupport
import Foundation
import GRDB
import XCTest
@testable import CaliCore

private func s(_ text: String) -> JSONValue { .string(text) }
private func n(_ number: Int) -> JSONValue { .number(Decimal(number)) }
private func id(_ number: Int) -> String { uuid(number).uuidString.lowercased() }

/// CON-011: `planned_workout.restBetweenExercisesSeconds` round-trips (pull → local → push) and feeds the session.
final class RestBetweenExercisesTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func seeded() throws -> (DatabaseQueue, ContentStore) {
        let db = try CaliDatabase.openInMemory() as! DatabaseQueue
        let store = ContentStore(writer: db)
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        return (db, store)
    }

    private func pull(_ db: DatabaseQueue, _ entity: Int, _ type: String, version: Int64 = 1, _ payload: [String: JSONValue]) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO sync_inbox (entity_type, entity_id, operation, server_version, change_id, payload_json, received_at) VALUES (?, ?, 'upsert', ?, 'c', ?, ?)",
                           arguments: [type, DBText.id(uuid(entity)), version,
                                       String(decoding: try SyncWireCoding.encoder().encode(JSONValue.object(payload)), as: UTF8.self), DBText.time(t0)])
            _ = try ContentApplier.applyInbox(db, now: t0)
        }
    }

    private func pullPlan(_ db: DatabaseQueue, rest: JSONValue?) throws {
        try pull(db, 700, "training_plan", ["id": s(id(700)), "title": s("Máy chủ"), "revision": n(1), "status": s("current"),
                                            "lineageId": s(id(700)), "kind": s("weekly"), "primaryDiscipline": s("calisthenics")])
        var workout: [String: JSONValue] = ["id": s(id(801)), "planId": s(id(700)), "weekday": n(3), "title": s("Thứ 4"), "orderIndex": n(0)]
        if let rest { workout["restBetweenExercisesSeconds"] = rest }
        try pull(db, 801, "planned_workout", workout)
    }

    private func workout(_ store: ContentStore) throws -> PlannedWorkout {
        try XCTUnwrap(store.load().plans.first { $0.id == uuid(700) }?.workouts.first)
    }

    func testPullWithAndWithoutTheKeyDecodes() throws {
        let (db, store) = try seeded()
        try pullPlan(db, rest: nil)
        XCTAssertNil(try workout(store).restBetweenExercisesSeconds)
        try pullPlan(db, rest: .null)
        XCTAssertNil(try workout(store).restBetweenExercisesSeconds)
        try pullPlan(db, rest: n(90))
        XCTAssertEqual(try workout(store).restBetweenExercisesSeconds, 90)
        try pullPlan(db, rest: nil) // server cleared it
        XCTAssertNil(try workout(store).restBetweenExercisesSeconds)
    }

    func testOutOfRangeValueIsNotApplied() throws {
        let (db, store) = try seeded()
        try pullPlan(db, rest: n(5000))
        XCTAssertNil(try store.load().plans.first { $0.id == uuid(700) }?.workouts.first { $0.id == uuid(801) })
    }

    func testPulled90IsKeptWhenThePlanIsEditedAndPushed() throws {
        let (db, store) = try seeded()
        try pullPlan(db, rest: n(90))
        var plan = try XCTUnwrap(store.load().plans.first { $0.id == uuid(700) })
        plan.workouts[0].title = "Thứ 4 (sửa)"
        try store.apply(ContentChange(plans: [plan]), now: t0)
        let json = try db.read {
            try String.fetchAll($0, sql: "SELECT json FROM sync_outbox WHERE entity_type = 'planned_workout' AND entity_id = ?", arguments: [id(801)])
        }
        let payload = try XCTUnwrap(json.last.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["payload"] as? [String: Any])
        XCTAssertEqual(payload["restBetweenExercisesSeconds"] as? Int, 90)
        XCTAssertEqual(payload["title"] as? String, "Thứ 4 (sửa)")
        XCTAssertEqual(try workout(store).restBetweenExercisesSeconds, 90)
    }

    func testSessionUsesThePlanValueElseDefault60() throws {
        let spec = Specs.hold(sets: 1)
        let base = PlannedWorkout(id: uuid(801), weekday: 3, title: "T", focus: "", exercises: [])
        var withValue = base
        withValue.restBetweenExercisesSeconds = 90
        for (workout, expected) in [(withValue, 90), (base, 60)] {
            let command = workout.createSession(commandId: uuid(1), sessionId: uuid(5000), executions: [spec, Specs.reps()])
            guard case .success(let t) = WorkoutReducer.reduce(nil, .createSession(command), now: t0) else { return XCTFail("create rejected") }
            XCTAssertEqual(t.state.transitionRestSeconds, expected)
            XCTAssertEqual(t.state.plannedWorkoutId, uuid(801))
        }
    }
}
