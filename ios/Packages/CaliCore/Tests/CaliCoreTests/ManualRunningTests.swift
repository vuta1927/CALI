import CaliCore
import CaliDomain
import Foundation
import XCTest

/// IOS-014: running results entered by hand and the bundled running exercises.
final class ManualRunningTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let race = ExecutionSpec(id: uuid(9010), plannedExerciseId: uuid(8010), exerciseId: uuid(7010), catalogVersion: 1,
                                     setCount: 1, target: .distance(distanceMeters: 10_000, durationSeconds: nil), restSeconds: 0)

    private func commands(_ f: CoreFixture, first: UUID, distance: Int, seconds: Int) -> [Command] {
        [
            .createSession(CreateSession(commandId: first, sessionId: sessionA, plannedWorkoutId: uuid(600), executions: [race])),
            f.startSet(),
            f.stopSet(),
            .confirmSet(ConfirmSet(commandId: f.freshId(), setResultId: uuid(6100), executionId: race.id, setIndex: 1,
                                   actualDistanceMeters: distance, actualDurationSeconds: seconds)),
            .finishSession(SimpleCommand(commandId: f.freshId())),
        ]
    }

    func testRecordSessionWritesSessionSetAndAuditOnceWithManualSource() throws {
        let f = try CoreFixture.inMemory()
        let audit = AuditEntry(id: uuid(900), at: t0, action: "Ghi kết quả thi", detail: "10 km")
        let result = try f.coordinator.recordSession(commands(f, first: uuid(900), distance: 10_000, seconds: 2_950), sessionTitle: "Kết quả thi", audit: audit)
        XCTAssertEqual(result.outcome.status, .applied)
        XCTAssertEqual(result.state?.status, .completed)

        let sets = try f.coordinator.setResults(sessionId: sessionA)
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].actual.distanceMeters, 10_000)
        XCTAssertEqual(sets[0].actual.durationSeconds, 2_950)
        XCTAssertEqual(sets[0].actual.source, .manual)
        XCTAssertEqual(sets[0].actual.pace?.formatted, "4:55/km")

        let content = try ContentStore(writer: f.coordinator.writer).load()
        XCTAssertEqual(content.history.map(\.id), [sessionA])
        XCTAssertEqual(content.history.first?.sets.first?.distanceMeters, 10_000)
        XCTAssertEqual(content.audit.map(\.id), [uuid(900)])

        let replay = try f.coordinator.recordSession(commands(f, first: uuid(900), distance: 10_000, seconds: 2_950), sessionTitle: "Kết quả thi", audit: audit)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(try f.coordinator.setResults(sessionId: sessionA).count, 1)
        XCTAssertEqual(try ContentStore(writer: f.coordinator.writer).load().audit.count, 1)
    }

    /// Over 24 h is refused by the domain; nothing of the half-built session or the audit is kept.
    func testRefusedStepRollsBackTheWholeManualSession() throws {
        let f = try CoreFixture.inMemory()
        let audit = AuditEntry(id: uuid(901), at: t0, action: "Ghi kết quả thi", detail: "-")
        let result = try f.coordinator.recordSession(commands(f, first: uuid(901), distance: 10_000, seconds: 86_401), sessionTitle: "Kết quả thi", audit: audit)
        XCTAssertEqual(result.outcome.status, .rejected)
        XCTAssertNil(try f.coordinator.activeState())
        XCTAssertNil(try f.coordinator.state(sessionId: sessionA))
        XCTAssertNil(try f.coordinator.processedOutcome(commandId: uuid(901)))
        let content = try ContentStore(writer: f.coordinator.writer).load()
        XCTAssertTrue(content.history.isEmpty)
        XCTAssertTrue(content.audit.isEmpty)
    }

    func testInsertMissingExercisesAddsOnlyNewIdsAndKeepsEdits() throws {
        let db = try CaliDatabase.openInMemory()
        let store = ContentStore(writer: db)
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        var edited = try XCTUnwrap(try store.load().catalog.first)
        edited.name = "Tên riêng"
        XCTAssertEqual(try store.apply(ContentChange(exercises: [edited]), now: t0), .applied)

        var bundled = Content.catalog
        bundled[0].name = "Tên gốc"
        bundled.append(Content.exercise(7010, type: .distance, name: "Chạy nhẹ"))
        XCTAssertEqual(try store.insertMissingExercises(bundled, now: t0), 1)
        XCTAssertEqual(try store.insertMissingExercises(bundled, now: t0), 0)
        let catalog = try store.load().catalog
        XCTAssertEqual(catalog.first?.name, "Tên riêng")
        XCTAssertEqual(catalog.last?.id, uuid(7010))
        XCTAssertEqual(catalog.last?.type, .distance)
    }
}
