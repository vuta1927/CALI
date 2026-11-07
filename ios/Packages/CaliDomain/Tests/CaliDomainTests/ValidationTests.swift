import CaliDomain
import XCTest

/// docs/03 §3 prescription rules and docs/07 §5 product limits.
final class ValidationTests: XCTestCase {

    private func fields(_ issues: [ValidationIssue]) -> [String] { issues.map(\.field) }

    func testPrescriptionBounds() {
        XCTAssertEqual(Prescription.staticHold(holdSeconds: 1).validate(), [])
        XCTAssertEqual(Prescription.staticHold(holdSeconds: 3_600).validate(), [])
        XCTAssertFalse(Prescription.staticHold(holdSeconds: 0).validate().isEmpty)
        XCTAssertFalse(Prescription.staticHold(holdSeconds: 3_601).validate().isEmpty)

        XCTAssertEqual(Prescription.reps(repMin: 8, repMax: 8).validate(), [])
        XCTAssertFalse(Prescription.reps(repMin: 0, repMax: 5).validate().isEmpty)
        XCTAssertEqual(Prescription.reps(repMin: 10, repMax: 8).validate().map(\.reason), [.inconsistent])

        XCTAssertEqual(Prescription.timedReps(timeSeconds: 30).validate(), [])
        XCTAssertFalse(Prescription.timedReps(timeSeconds: 0).validate().isEmpty)

        XCTAssertEqual(Prescription.interval(workSeconds: 20, restSeconds: 10).validate(), [])
        XCTAssertFalse(Prescription.interval(workSeconds: 0, restSeconds: 10).validate().isEmpty)
        XCTAssertFalse(Prescription.interval(workSeconds: 20, restSeconds: 0).validate().isEmpty, "docs/03: rest > 0 (CON-002 Q7)")

        XCTAssertEqual(Prescription.skillAttempt(attempts: 3).validate(), [])
        XCTAssertFalse(Prescription.skillAttempt(attempts: 0).validate().isEmpty)
    }

    func testTimedTargetsExposeDuration() {
        XCTAssertEqual(Prescription.staticHold(holdSeconds: 12).targetDurationSeconds, 12)
        XCTAssertEqual(Prescription.timedReps(timeSeconds: 30).targetDurationSeconds, 30)
        XCTAssertEqual(Prescription.interval(workSeconds: 20, restSeconds: 10).targetDurationSeconds, 20)
        XCTAssertNil(Prescription.reps(repMin: 5, repMax: 8).targetDurationSeconds)
        XCTAssertNil(Prescription.skillAttempt(attempts: 3).targetDurationSeconds)
    }

    func testExecutionSpecLimits() {
        XCTAssertEqual(Specs.hold(sets: 1, rest: 0).validate(), [])
        XCTAssertEqual(Specs.hold(sets: 20, rest: 3_600).validate(), [])
        XCTAssertEqual(fields(Specs.hold(sets: 0).validate()), ["setCount"])
        XCTAssertEqual(fields(Specs.hold(sets: 21).validate()), ["setCount"])
        XCTAssertEqual(fields(Specs.hold(rest: -1).validate()), ["restSeconds"])
        XCTAssertEqual(fields(Specs.hold(rest: 3_601).validate()), ["restSeconds"])
        var spec = Specs.hold()
        spec.catalogVersion = 0
        XCTAssertEqual(fields(spec.validate()), ["catalogVersion"])
    }

    func testCreateSessionValidation() {
        let h = Harness()
        guard case .validationFailed(let empty)? = h.reject(h.create([])) else { return XCTFail() }
        XCTAssertEqual(fields(empty), ["executions"])

        guard case .validationFailed(let dup)? = h.reject(h.create([Specs.hold(), Specs.reps(id: Specs.holdId)])) else { return XCTFail() }
        XCTAssertEqual(fields(dup), ["executions.id"])

        guard case .validationFailed(let bad)? = h.reject(h.create([Specs.hold(), Specs.hold(sets: 21, id: uuid(9003))])) else { return XCTFail() }
        XCTAssertEqual(fields(bad), ["executions[1].setCount"])

        let many = (0..<51).map { Specs.reps(id: uuid(10_000 + $0)) }
        guard case .validationFailed(let tooMany)? = h.reject(h.create(many)) else { return XCTFail() }
        XCTAssertEqual(fields(tooMany), ["executions"])
    }

    func testCountdownBounds() {
        let h = Harness()
        h.toReady()
        XCTAssertEqual(h.reject(h.startSet(countdown: 11))?.code, "validation_failed")
        XCTAssertEqual(h.reject(h.startSet(countdown: -1))?.code, "validation_failed")
        h.send(h.startSet(countdown: 10))
    }

    func testConfirmRequiresPrimaryActualForType() {
        let cases: [(Prescription, String)] = [
            (.staticHold(holdSeconds: 10), "actualHoldMs"),
            (.reps(repMin: 5, repMax: 8), "actualReps"),
            (.timedReps(timeSeconds: 30), "actualReps"),
            (.interval(workSeconds: 20, restSeconds: 10), "actualWorkMs"),
        ]
        for (target, field) in cases {
            let h = Harness()
            let spec = ExecutionSpec(id: uuid(9100), exerciseId: uuid(7100), catalogVersion: 1, setCount: 1, target: target, restSeconds: 60)
            h.send(h.create([spec]))
            h.send(h.startSet(countdown: 0))
            h.clock.advance(by: 1)
            h.send(h.stopSet())
            let key = h.s.currentSetKey!
            let empty = Command.confirmSet(ConfirmSet(commandId: h.freshId(), setResultId: h.freshId(), executionId: key.executionId, setIndex: key.setIndex))
            guard case .validationFailed(let issues)? = h.reject(empty) else { XCTFail("\(target)"); continue }
            XCTAssertTrue(fields(issues).contains(field), "\(target): \(issues)")
            h.send(h.confirm())
            XCTAssertEqual(h.s.phase, .reviewingSummary)
        }
    }

    func testSkillAttemptAcceptsStatusOnly() {
        let h = Harness()
        let spec = ExecutionSpec(id: uuid(9200), exerciseId: uuid(7200), catalogVersion: 1, setCount: 1, target: .skillAttempt(attempts: 3), restSeconds: 60)
        h.send(h.create([spec]))
        h.send(h.startSet(countdown: 0))
        h.send(h.stopSet())
        let key = h.s.currentSetKey!
        let t = h.send(.confirmSet(ConfirmSet(commandId: h.freshId(), setResultId: h.freshId(), executionId: key.executionId, setIndex: key.setIndex, status: .failed)))
        XCTAssertEqual(t.setRecords.first?.status, .failed)
        XCTAssertEqual(h.s.confirmedSetCount, 1, "failed attempts are recorded results, not skips")
    }

    func testConfirmRejectsSkippedStatusNegativeActualsAndRpeOutOfRange() {
        let h = Harness()
        h.toAwaitingResult()
        let key = h.s.currentSetKey!
        func confirm(_ mutate: (inout ConfirmSet) -> Void) -> [String] {
            var c = ConfirmSet(commandId: h.freshId(), setResultId: h.freshId(), executionId: key.executionId, setIndex: key.setIndex, actualHoldMs: 10_000)
            mutate(&c)
            guard case .validationFailed(let issues)? = h.reject(.confirmSet(c)) else { return [] }
            return fields(issues)
        }
        XCTAssertEqual(confirm { $0.status = .skipped }, ["status"])
        XCTAssertEqual(confirm { $0.actualHoldMs = -1 }, ["actualHoldMs"])
        XCTAssertEqual(confirm { $0.actualReps = -1 }, ["actualReps"])
        XCTAssertEqual(confirm { $0.actualRestMs = -5 }, ["actualRestMs"])
        XCTAssertEqual(confirm { $0.rpe = 0 }, ["rpe"])
        XCTAssertEqual(confirm { $0.rpe = 11 }, ["rpe"])
        XCTAssertEqual(h.s.phase, .awaitingResult)
        XCTAssertEqual(h.s.resolvedSets, [])
    }

    func testReasonLengthLimit() {
        let h = Harness()
        h.toReady()
        let long = String(repeating: "x", count: 501)
        XCTAssertEqual(h.reject(h.skip(reason: long))?.code, "validation_failed")
        XCTAssertEqual(h.reject(h.abandon(long))?.code, "validation_failed")
        h.send(h.abandon(String(repeating: "x", count: 500)))
    }
}
