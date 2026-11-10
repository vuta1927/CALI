import CaliCore
import CaliDomain
import Foundation
import XCTest

/// IOS-016: criteria values, pain and load reach the database and the history; settings keep working
/// when an older build saved them without `weightUnit`.
final class CriteriaPersistenceTests: XCTestCase {
    private let squat = ExecutionSpec(id: uuid(9020), plannedExerciseId: uuid(8020), exerciseId: uuid(7020), catalogVersion: 1,
                                      setCount: 1, target: .load(reps: 5, loadKg: 60), restSeconds: 90)

    func testCriteriaAndLoadSurviveInSetResultsAndHistory() throws {
        let f = try CoreFixture.inMemory()
        let criteria: [String: CriteriaValue] = ["technique": .token("good"), "equipment": .tokens(["barbell"])]
        let commands: [Command] = [
            .createSession(CreateSession(commandId: f.freshId(), sessionId: sessionA, plannedWorkoutId: nil, executions: [squat])),
            f.startSet(), f.stopSet(),
            .confirmSet(ConfirmSet(commandId: f.freshId(), setResultId: uuid(6200), executionId: squat.id, setIndex: 1, actualReps: 5, rpe: 8,
                                   actualLoadKg: Decimal(string: "62.5"), painReported: true, criteriaVersion: 1, criteria: criteria)),
            .finishSession(SimpleCommand(commandId: f.freshId())),
        ]
        let result = try f.coordinator.recordSession(commands, sessionTitle: "Squat", audit: AuditEntry(id: uuid(901), at: t0, action: "t", detail: ""))
        XCTAssertEqual(result.outcome.status, .applied)
        let stored = try XCTUnwrap(try f.coordinator.setResults(sessionId: sessionA).first)
        XCTAssertEqual(stored.actual.loadKg, Decimal(string: "62.5"))
        XCTAssertEqual(stored.actual.painReported, true)
        XCTAssertEqual(stored.actual.criteriaVersion, 1)
        XCTAssertEqual(stored.actual.criteria, criteria)
        let set = try XCTUnwrap(try ContentStore(writer: f.coordinator.writer).load().history.first?.sets.first)
        XCTAssertEqual(set.criteria, criteria)
        XCTAssertEqual(set.painReported, true)
        XCTAssertEqual(set.rpe, 8)
    }

    func testSettingsFromAnOlderBuildDecodeAndDefaultToKg() throws {
        let old = Data(#"{"countdownSeconds":5,"hapticsEnabled":false,"notificationsEnabled":true,"liveActivityEnabled":true,"hasSeenWelcome":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertEqual(settings.countdownSeconds, 5)
        XCTAssertEqual(settings.weightUnit, .kg)
        let back = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(AppSettings(weightUnit: .lb)))
        XCTAssertEqual(back.weightUnit, .lb)
    }
}
