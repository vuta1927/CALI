import Foundation
import XCTest
@testable import CaliDomain

/// CON-007: the ADR-063 rules, with the same vectors as fixtures/validation/business_rules.json.
final class BodyMeasurementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func issues(_ value: Decimal, at offset: TimeInterval = -900) -> [ValidationIssue] {
        BodyMeasurementRules.validate(kind: .weight, value: value, measuredAt: now.addingTimeInterval(offset), now: now)
    }

    func testWeightRangeIsTwentyToFiveHundredInclusive() {
        XCTAssertTrue(issues(20).isEmpty)
        XCTAssertTrue(issues(500).isEmpty)
        XCTAssertEqual(issues(19.99).map(\.field), ["value"])
        XCTAssertEqual(issues(500.01).map(\.field), ["value"])
        XCTAssertEqual(issues(0).map(\.field), ["value"])
    }

    func testMoreThanTwoDecimalsIsRejectedNotRounded() {
        XCTAssertTrue(issues(Decimal(string: "72.45")!).isEmpty)
        XCTAssertTrue(issues(Decimal(string: "72.4")!).isEmpty)
        XCTAssertEqual(issues(Decimal(string: "72.455")!).map(\.field), ["value"], "business_rules: body_weight_with_three_decimals")
    }

    func testAFutureMeasurementIsRejectedNeverClamped() {
        XCTAssertTrue(issues(72.4, at: 0).isEmpty, "measuredAt equal to the change time is allowed")
        XCTAssertEqual(issues(72.4, at: 86_400).map(\.field), ["measuredAt"], "business_rules: body_measured_at_in_the_future")
    }

    func testEntriesAreNewestFirstWithoutDeletedOnesAndSeveralPerDayAreKept() {
        let day = now.addingTimeInterval(-3600)
        let a = BodyMeasurement(value: 72, measuredAt: day)
        let b = BodyMeasurement(value: 71.5, measuredAt: day.addingTimeInterval(1800))
        let gone = BodyMeasurement(value: 90, measuredAt: now, deletedAt: now)
        XCTAssertEqual(BodyMeasurementRules.entries([a, gone, b]).map(\.id), [b.id, a.id])
        XCTAssertEqual(BodyMeasurementRules.lastChange([a, gone, b]), Decimal(string: "-0.5"))
        XCTAssertNil(BodyMeasurementRules.lastChange([a]))
    }

    func testJSONShapeMatchesTheContractFields() throws {
        let m = BodyMeasurement(id: UUID(uuidString: "cb000000-0000-4000-8000-000000000035")!, value: Decimal(string: "72.4")!,
                                measuredAt: Date(timeIntervalSince1970: 1_800_000_000))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys.map { $0 } ?? []).subtracting(["deletedAt"]), ["id", "kind", "value", "measuredAt"],
                       "no unit, source or note field (ADR-063)")
        XCTAssertEqual(object?["kind"] as? String, "weight")
    }
}
