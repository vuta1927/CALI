import CaliDomain
import XCTest

/// IOS-016 / CON-008: criteria config, applicability, value rules and weight display.
final class CriteriaTests: XCTestCase {
    private let bundled = CriteriaConfig.bundled

    func testBundledConfigMatchesTheFixtureV1() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("fixtures/criteria_config.json"))
        let fixture = try DomainJSON.makeDecoder().decode(CriteriaConfig.self, from: data)
        XCTAssertEqual(fixture.version, bundled.version)
        XCTAssertEqual(fixture.criteria, bundled.criteria, "the bundled config is exactly db/008 seed = fixture v1")
    }

    func testApplicableCriteriaFollowDisciplineMeasurementAndExerciseIds() {
        let id = UUID()
        func ids(_ type: ExerciseType) -> [String] { bundled.applicable(exerciseId: id, type: type).map(\.id) }
        XCTAssertEqual(ids(.staticHold), ["technique", "condition", "pain"])
        XCTAssertEqual(ids(.load), ["technique", "rpe", "equipment", "pain"])
        XCTAssertEqual(ids(.distance), ["technique", "pain"], "running: only criteria for any discipline")

        var config = bundled
        config.criteria.append(Criterion(id: "grip", type: "choice", label: "Tay", appliesTo: CriteriaAppliesTo(disciplines: ["*"], measurementTypes: [.hold], exerciseIds: [id]),
                                         options: [CriterionOption(v: "wide", label: "Rộng")]))
        config.criteria.append(Criterion(id: "future", type: "wheel", label: "Mới", appliesTo: CriteriaAppliesTo(disciplines: ["*"])))
        config.criteria.append(Criterion(id: "off", type: "toggle", label: "Tắt", appliesTo: CriteriaAppliesTo(disciplines: ["*"]), enabled: false))
        XCTAssertTrue(config.applicable(exerciseId: id, type: .staticHold).map(\.id).contains("grip"))
        XCTAssertFalse(config.applicable(exerciseId: UUID(), type: .staticHold).map(\.id).contains("grip"), "other exercise")
        XCTAssertFalse(config.applicable(exerciseId: id, type: .reps).map(\.id).contains("grip"), "other measurement type")
        let all = config.applicable(exerciseId: id, type: .staticHold).map(\.id)
        XCTAssertFalse(all.contains("future"), "unknown type is skipped, not an error")
        XCTAssertFalse(all.contains("off"))
    }

    func testValuesAreCheckedAgainstTheirVersion() {
        func fields(_ v: [String: CriteriaValue], _ c: CriteriaConfig? = CriteriaConfig.bundled) -> [String] {
            CriteriaValidation.validate(v, config: c).map(\.field)
        }
        XCTAssertEqual(fields(["technique": .token("good"), "condition": .tokens(["assist", "equip"])]), [])
        XCTAssertEqual(fields(["technique": .token("great")]), ["criteria.technique"])
        XCTAssertEqual(fields(["condition": .tokens(["nope"])]), ["criteria.condition"])
        XCTAssertEqual(fields(["technique": .bool(true)]), ["criteria.technique"], "wrong kind")
        XCTAssertEqual(fields(["mystery": .token("x")]), ["criteria.mystery"], "not a criterion of that version")
        XCTAssertEqual(fields(["rpe": .number(8)]), ["criteria.rpe"], "rpe and pain are columns, never in the map")
        XCTAssertEqual(fields(["pain": .bool(true)]), ["criteria.pain"])
        XCTAssertEqual(fields(["a": .tokens(["x", "x"])], nil), ["criteria.a"], "duplicate tokens")

        var scale = CriteriaConfig.bundled
        scale.criteria.append(Criterion(id: "focus", type: "scale", label: "Tập trung", appliesTo: CriteriaAppliesTo(disciplines: ["*"]), min: 1, max: 5))
        XCTAssertEqual(fields(["focus": .number(5)], scale), [])
        XCTAssertEqual(fields(["focus": .number(6)], scale), ["criteria.focus"])
    }

    func testMapSizeLimits() {
        let many = Dictionary(uniqueKeysWithValues: (0..<21).map { ("k\($0)", CriteriaValue.bool(true)) })
        XCTAssertEqual(CriteriaValidation.validate(many, config: nil).map(\.field), ["criteria.*"])
        let big = ["note": CriteriaValue.tokens(Array(repeating: "a", count: 3000))]
        XCTAssertFalse(CriteriaValidation.validate(big, config: nil).isEmpty)
    }

    func testConfirmCarriesCriteriaOnlyWithItsVersion() {
        let h = Harness()
        h.toAwaitingResult()
        let key = h.s.currentSetKey!
        func confirm(_ mutate: (inout ConfirmSet) -> Void) -> [String]? {
            var c = ConfirmSet(commandId: h.freshId(), setResultId: h.freshId(), executionId: key.executionId, setIndex: key.setIndex, actualHoldMs: 10_000)
            mutate(&c)
            guard case .validationFailed(let issues)? = h.reject(.confirmSet(c)) else { return nil }
            return issues.map(\.field)
        }
        XCTAssertEqual(confirm { $0.criteria = ["technique": .token("ok")] }, ["criteria"])
        XCTAssertEqual(confirm { $0.criteriaVersion = 1 }, ["criteria"])
        XCTAssertEqual(confirm { $0.criteriaVersion = 0; $0.criteria = [:] }, ["criteriaVersion"])
        XCTAssertEqual(confirm { $0.criteriaVersion = 1; $0.criteria = ["rpe": .number(8)] }, ["criteria.rpe"])
        let ok = ConfirmSet(commandId: h.freshId(), setResultId: h.freshId(), executionId: key.executionId, setIndex: key.setIndex, actualHoldMs: 10_000,
                            painReported: true, criteriaVersion: 1, criteria: ["technique": .token("ok")])
        let t = h.send(.confirmSet(ok))
        let record = t.events.compactMap { e -> SetRecord? in if case .setConfirmed(let rec) = e { rec } else { nil } }.first
        XCTAssertEqual(record?.actual.painReported, true)
        XCTAssertEqual(record?.actual.criteriaVersion, 1)
        XCTAssertEqual(record?.actual.criteria, ["technique": .token("ok")])
    }

    func testCriteriaValueRoundTripsAsPlainJSON() throws {
        let values: [String: CriteriaValue] = ["a": .token("x"), "b": .number(3), "c": .bool(false), "d": .tokens(["p", "q"])]
        let data = try DomainJSON.makeEncoder().encode(values)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["a"] as? String, "x")
        XCTAssertEqual(object["c"] as? Bool, false)
        XCTAssertEqual(object["d"] as? [String], ["p", "q"])
        XCTAssertEqual(try DomainJSON.makeDecoder().decode([String: CriteriaValue].self, from: data), values)
    }

    func testUnreadableCachedConfigFallsBackToBundled() throws {
        XCTAssertEqual(CriteriaConfig.resolve(cached: nil), .bundled)
        XCTAssertEqual(CriteriaConfig.resolve(cached: Data("not json".utf8)), .bundled)
        XCTAssertEqual(CriteriaConfig.resolve(cached: Data(#"{"version":0,"supportedTypes":[],"criteria":[]}"#.utf8)), .bundled)
        var newer = CriteriaConfig.bundled
        newer.version = 2
        let data = try DomainJSON.makeEncoder().encode(newer)
        XCTAssertEqual(CriteriaConfig.resolve(cached: data).version, 2)
    }

    func testWeightUnitDisplayAndEntry() {
        XCTAssertEqual(WeightUnit.kg.display(kg: 57.5), 57.5)
        XCTAssertEqual(WeightUnit.lb.display(kg: 60), 132.3)
        let kg = WeightUnit.lb.kg(fromDisplayed: 135)
        XCTAssertEqual(kg, Decimal(string: "61.23"), "stored kg has at most 2 decimals (ADR-062)")
        XCTAssertEqual(WeightUnit.lb.display(kg: kg), 135, "round trip of a typed lb value")
        XCTAssertEqual(WeightUnit.kg.kg(fromDisplayed: Decimal(string: "57.555")!), Decimal(string: "57.555")!, "kg is never rounded; the domain rejects")
    }
}
