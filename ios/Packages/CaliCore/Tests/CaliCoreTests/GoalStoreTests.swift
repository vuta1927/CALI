import CaliCore
import CaliDomain
import Foundation
import GRDB
import XCTest

/// IOS-015: phases (per revision) and goals (per lineage) in schema v3_goals.
final class GoalStoreTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testPhasesAndGoalsRoundTripAndSoftDelete() throws {
        let db = try CaliDatabase.openInMemory()
        let store = ContentStore(writer: db)
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        var plan = try XCTUnwrap(try store.load().plans.first)
        let base = PlanPhase(id: uuid(1100), name: "Nền tảng", weeks: 4, description: "Giữ ngắn")
        let peak = PlanPhase(id: uuid(1101), name: "Đỉnh", weeks: 2)
        plan.phases = [base, peak]
        let goal = PlanGoal(id: uuid(1200), planLineageId: plan.lineageId, title: "Plank 30 giây", indicatorId: "best_hold_seconds",
                            exerciseId: uuid(7001), baseline: 12, target: .value(30), scopePhaseId: base.id, pinned: true)
        XCTAssertEqual(try store.apply(ContentChange(plans: [plan], goals: [goal], audit: AuditEntry(id: uuid(901), at: t0, action: "a", detail: "")), now: t0), .applied)

        var loaded = try store.load()
        XCTAssertEqual(loaded.plans.first?.phases, [base, peak])
        XCTAssertEqual(loaded.plans.first?.program, .weekly(totalWeeks: 6))
        XCTAssertEqual(loaded.goals, [goal])

        plan.phases = [peak]
        var archived = goal
        archived.status = .archived
        archived.pinned = false
        XCTAssertEqual(try store.apply(ContentChange(plans: [plan], goals: [archived]), now: t0), .applied)
        loaded = try store.load()
        XCTAssertEqual(loaded.plans.first?.phases, [peak])
        XCTAssertEqual(loaded.goals.first?.status, .archived)
        let deletedRow = try db.read { try Row.fetchOne($0, sql: "SELECT deleted_at FROM plan_phases WHERE id = ?", arguments: [uuid(1100).uuidString.lowercased()]) }
        XCTAssertNotNil(deletedRow?["deleted_at"] as String?, "phases are soft-deleted, never removed")

        var gone = archived
        gone.deletedAt = t0
        _ = try store.apply(ContentChange(goals: [gone]), now: t0)
        XCTAssertTrue(try store.load().goals.isEmpty)
    }

    /// A bad goal row rolls back the whole change (here: a status outside the CHECK).
    func testInvalidPhaseRollsBackTheChange() throws {
        let store = ContentStore(writer: try CaliDatabase.openInMemory())
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        var plan = try XCTUnwrap(try store.load().plans.first)
        plan.title = "Đổi tên"
        plan.phases = [PlanPhase(id: uuid(1100), name: "Quá dài", weeks: 60)]
        XCTAssertThrowsError(try store.apply(ContentChange(plans: [plan]), now: t0))
        XCTAssertEqual(try store.load().plans.first?.title, Content.plan().title)
    }
}
