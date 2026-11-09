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

    /// CON-006 (ADR-062): reps 1..500, loadKg 0..1000 with at most 2 decimals (rejected, never rounded).
    func testLoadPrescriptionBounds() {
        func kg(_ text: String) -> Decimal { Decimal(string: text)! }
        XCTAssertEqual(Prescription.load(reps: 5, loadKg: kg("60")).validate(), [])
        XCTAssertEqual(Prescription.load(reps: 1, loadKg: kg("0")).validate(), [], "0 kg is a valid load")
        XCTAssertEqual(Prescription.load(reps: 500, loadKg: kg("1000")).validate(), [])
        XCTAssertEqual(Prescription.load(reps: 5, loadKg: kg("57.25")).validate(), [])
        XCTAssertEqual(fields(Prescription.load(reps: 0, loadKg: kg("60")).validate()), ["target.reps"])
        XCTAssertEqual(fields(Prescription.load(reps: 501, loadKg: kg("60")).validate()), ["target.reps"])
        XCTAssertEqual(fields(Prescription.load(reps: 5, loadKg: kg("-2.5")).validate()), ["target.loadKg"])
        XCTAssertEqual(fields(Prescription.load(reps: 5, loadKg: kg("1000.5")).validate()), ["target.loadKg"])
        XCTAssertEqual(fields(Prescription.load(reps: 5, loadKg: kg("57.555")).validate()), ["target.loadKg"])
        XCTAssertNil(Prescription.load(reps: 5, loadKg: kg("60")).targetDurationSeconds, "load sets end by explicit stop")
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

    /// CON-006 (ADR-062): a load set needs actualReps + actualLoadKg; load is only allowed on a load target.
    func testLoadActuals() {
        let h = Harness()
        let spec = ExecutionSpec(id: uuid(9300), exerciseId: uuid(7300), catalogVersion: 1, setCount: 1, target: .load(reps: 5, loadKg: 60), restSeconds: 90)
        h.send(h.create([spec]))
        h.send(h.startSet(countdown: 0))
        h.send(h.stopSet())
        let key = h.s.currentSetKey!
        func confirm(reps: Int?, kg: String?) -> [String] {
            let c = ConfirmSet(commandId: h.freshId(), setResultId: h.freshId(), executionId: key.executionId, setIndex: key.setIndex,
                               actualReps: reps, actualLoadKg: kg.flatMap { Decimal(string: $0) })
            guard case .validationFailed(let issues)? = h.reject(.confirmSet(c)) else { return [] }
            return fields(issues)
        }
        XCTAssertEqual(confirm(reps: 5, kg: nil), ["actualLoadKg"])
        XCTAssertEqual(confirm(reps: nil, kg: "60"), ["actualReps"])
        XCTAssertEqual(confirm(reps: 5, kg: "-1"), ["actualLoadKg"])
        XCTAssertEqual(confirm(reps: 5, kg: "1000.01"), ["actualLoadKg"])
        XCTAssertEqual(confirm(reps: 5, kg: "57.555"), ["actualLoadKg"])
        XCTAssertEqual(h.s.phase, .awaitingResult)
        let t = h.send(.confirmSet(ConfirmSet(commandId: h.freshId(), setResultId: h.freshId(), executionId: key.executionId, setIndex: key.setIndex,
                                              actualReps: 5, actualLoadKg: Decimal(string: "57.5"))))
        XCTAssertEqual(t.setRecords.first?.actual.loadKg, Decimal(string: "57.5"))
        XCTAssertEqual(t.setRecords.first?.actual.reps, 5)

        let other = Harness()
        other.toAwaitingResult()
        let k = other.s.currentSetKey!
        let wrong = ConfirmSet(commandId: other.freshId(), setResultId: other.freshId(), executionId: k.executionId, setIndex: k.setIndex,
                               actualHoldMs: 10_000, actualLoadKg: 10)
        guard case .validationFailed(let issues)? = other.reject(.confirmSet(wrong)) else { return XCTFail("load on a hold set") }
        XCTAssertEqual(issues.map(\.field), ["actualLoadKg"])
        XCTAssertEqual(issues.map(\.reason), [.notAllowed])
    }

    /// IOS-014 (CON-004): running segments take distance/time by hand, `source = manual`, pace derived.
    func testRunningActuals() {
        let h = Harness()
        let spec = ExecutionSpec(id: uuid(9400), exerciseId: uuid(7400), catalogVersion: 1, setCount: 1,
                                 target: .distance(distanceMeters: 1000, durationSeconds: 290), restSeconds: 120)
        h.send(h.create([spec]))
        h.send(h.startSet(countdown: 0))
        XCTAssertNil(h.s.phaseDeadlineAt, "a distance segment ends when the user stops")
        h.send(h.stopSet())
        let key = h.s.currentSetKey!
        func confirm(_ meters: Int?, _ seconds: Int?, status: SetStatus = .completed) -> [String] {
            let c = ConfirmSet(commandId: h.freshId(), setResultId: h.freshId(), executionId: key.executionId, setIndex: key.setIndex,
                               status: status, actualDistanceMeters: meters, actualDurationSeconds: seconds)
            guard case .validationFailed(let issues)? = h.reject(.confirmSet(c)) else { return [] }
            return fields(issues)
        }
        XCTAssertEqual(confirm(0, 290), ["actualDistanceMeters"], "pace needs a distance")
        XCTAssertEqual(confirm(1000, 0), ["actualDurationSeconds"], "pace needs a time")
        XCTAssertEqual(confirm(1000, nil), ["actualDurationSeconds"])
        XCTAssertEqual(confirm(1000, 86_401), ["actualDurationSeconds"], "over 24 h is rejected")
        XCTAssertEqual(confirm(1_000_001, 290), ["actualDistanceMeters"])
        XCTAssertEqual(h.s.phase, .awaitingResult)
        let t = h.send(.confirmSet(ConfirmSet(commandId: h.freshId(), setResultId: h.freshId(), executionId: key.executionId, setIndex: key.setIndex,
                                              actualDistanceMeters: 1000, actualDurationSeconds: 86_400)))
        let actual = t.setRecords.first?.actual
        XCTAssertEqual(actual?.distanceMeters, 1000)
        XCTAssertEqual(actual?.durationSeconds, 86_400)
        XCTAssertEqual(actual?.source, .manual)
        XCTAssertEqual(actual?.pace?.formatted, "24:00:00/km")

        let timed = Harness()
        let segment = ExecutionSpec(id: uuid(9401), exerciseId: uuid(7401), catalogVersion: 1, setCount: 1,
                                    target: .duration(durationSeconds: 300), restSeconds: 120)
        timed.send(timed.create([segment]))
        timed.send(timed.startSet(countdown: 0))
        XCTAssertNotNil(timed.s.phaseDeadlineAt, "a timed segment gets an end prompt, never an automatic result")
        timed.send(timed.stopSet())
        let k = timed.s.currentSetKey!
        let noTime = ConfirmSet(commandId: timed.freshId(), setResultId: timed.freshId(), executionId: k.executionId, setIndex: k.setIndex,
                                actualDistanceMeters: 1200)
        guard case .validationFailed(let missing)? = timed.reject(.confirmSet(noTime)) else { return XCTFail("duration needs a time") }
        XCTAssertEqual(fields(missing), ["actualDurationSeconds"])
        let ok = timed.send(.confirmSet(ConfirmSet(commandId: timed.freshId(), setResultId: timed.freshId(), executionId: k.executionId,
                                                   setIndex: k.setIndex, actualDurationSeconds: 300)))
        XCTAssertNil(ok.setRecords.first?.actual.pace, "distance is optional for a timed segment")

        let other = Harness()
        other.toAwaitingResult()
        let hold = other.s.currentSetKey!
        let wrong = ConfirmSet(commandId: other.freshId(), setResultId: other.freshId(), executionId: hold.executionId, setIndex: hold.setIndex,
                               actualHoldMs: 10_000, actualDistanceMeters: 500)
        guard case .validationFailed(let issues)? = other.reject(.confirmSet(wrong)) else { return XCTFail("distance on a hold set") }
        XCTAssertEqual(issues.map(\.field), ["actualDistanceMeters"])
        XCTAssertEqual(issues.map(\.reason), [.notAllowed])
    }

    func testRunningPrescriptionRoundTripsWithContractKeys() throws {
        let target = Prescription.distance(distanceMeters: 5000, durationSeconds: nil)
        let json = String(decoding: try DomainJSON.makeEncoder().encode(target), as: UTF8.self)
        XCTAssertTrue(json.contains("\"kind\":\"distance\""), json)
        XCTAssertFalse(json.contains("durationSeconds"), json)
        XCTAssertEqual(try DomainJSON.makeDecoder().decode(Prescription.self, from: Data(json.utf8)), target)
        XCTAssertEqual(Prescription.duration(durationSeconds: 0).validate().map(\.field), ["target.durationSeconds"])
        XCTAssertEqual(Prescription.distance(distanceMeters: 500_001, durationSeconds: nil).validate().map(\.field), ["target.distanceMeters"])
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
