import CaliDomain
import XCTest

/// Wire shapes must match contracts/entity-payloads.schema.json (snake_case enums, `kind` targets).
final class CodableTests: XCTestCase {

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try DomainJSON.makeEncoder().encode(value), as: UTF8.self)
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try DomainJSON.makeEncoder().encode(value)
        XCTAssertEqual(try DomainJSON.makeDecoder().decode(T.self, from: data), value, file: file, line: line)
    }

    func testPrescriptionMatchesContractShape() throws {
        XCTAssertEqual(try json(Prescription.staticHold(holdSeconds: 12)), #"{"holdSeconds":12,"kind":"static_hold"}"#)
        XCTAssertEqual(try json(Prescription.reps(repMin: 8, repMax: 10)), #"{"kind":"reps","repMax":10,"repMin":8}"#)
        XCTAssertEqual(try json(Prescription.timedReps(timeSeconds: 30)), #"{"kind":"timed_reps","timeSeconds":30}"#)
        XCTAssertEqual(try json(Prescription.interval(workSeconds: 20, restSeconds: 10)), #"{"kind":"interval","restSeconds":10,"workSeconds":20}"#)
        XCTAssertEqual(try json(Prescription.skillAttempt(attempts: 3)), #"{"attempts":3,"kind":"skill_attempt"}"#)
    }

    /// CON-006: `{ "kind": "load", "reps": 5, "loadKg": 57.5 }` keeps the exact decimal (kg, ADR-046/ADR-062).
    func testLoadPrescriptionMatchesContractShape() throws {
        let load = Prescription.load(reps: 5, loadKg: Decimal(string: "57.5")!)
        XCTAssertEqual(try json(load), #"{"kind":"load","loadKg":57.5,"reps":5}"#)
        try roundTrip(load)
        let decoded = try DomainJSON.makeDecoder().decode(Prescription.self, from: Data(#"{"kind":"load","reps":5,"loadKg":60}"#.utf8))
        XCTAssertEqual(decoded, .load(reps: 5, loadKg: 60))
        XCTAssertEqual(decoded.type, .load)
    }

    func testEnumsUseSnakeCase() throws {
        XCTAssertEqual(try json([Phase.preCountdown, .awaitingResult, .reviewingSummary]), #"["pre_countdown","awaiting_result","reviewing_summary"]"#)
        XCTAssertEqual(Set(SessionStatus.allCases.map(\.rawValue)), ["active", "completed", "abandoned"])
        XCTAssertEqual(Set(SetStatus.allCases.map(\.rawValue)), ["completed", "failed", "skipped"])
    }

    func testCommandRoundTripWithTypeDiscriminator() throws {
        let h = Harness()
        h.toAwaitingResult()
        let commands: [Command] = CommandKind.allCases.map { h.command($0) }
        for c in commands { try roundTrip(c) }
        let text = try json(h.command(.confirmSet))
        XCTAssertTrue(text.contains(#""type":"confirm_set""#), text)
    }

    func testSessionStateRoundTripAtEveryPhase() throws {
        for phase in Phase.allCases {
            let h = Harness()
            h.reach(phase)
            try roundTrip(h.s)
        }
    }

    func testDraftWithDeadlineReasonRoundTrips() throws {
        let h = Harness()
        h.toExercising()
        h.clock.sleep(for: 40)
        h.reconcile()
        try roundTrip(h.s)
        try roundTrip(h.s.pendingResult!)
    }
}
