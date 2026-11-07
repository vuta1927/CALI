import CaliDomain
import Foundation
import XCTest

/// Runs the draft CON-002 reducer vectors in `<repo>/fixtures/reducer/*.json`.
///
/// Fixtures are read from the repository tree (not bundled as SwiftPM resources) so that the same
/// files can later be consumed by non-Swift tooling and stay a single source of truth outside the
/// package. Location: `CALI_REDUCER_FIXTURES_DIR` if set, else resolved relative to this source file
/// (`#filePath`). In Docker, mount the **repo root** (not just the package) so the path resolves.
/// A missing directory is a hard failure, never a silent skip.
final class ReducerFixtureTests: XCTestCase {

    // MARK: Format

    struct Fixture: Decodable {
        var name: String
        var description: String
        var steps: [Step]
    }

    struct Step: Decodable {
        var now: Date
        var command: Command?
        var reconcile: ReconcileInput?
        var expect: Expect
    }

    struct ReconcileInput: Decodable {
        var previousNow: Date?
        var monotonicElapsed: TimeInterval?
        var acknowledgeClockJump: Bool?
    }

    /// Absent keys are not checked. `phaseDeadlineAt` / `pendingSuggestedActualMs` distinguish
    /// "absent" (unchecked) from explicit JSON `null` (must be nil).
    struct Expect: Decodable {
        var error: String?
        var phase: Phase?
        var status: SessionStatus?
        var revision: Int?
        var events: [String]?
        var signals: [String]?
        var currentExecutionIndex: Int?
        var currentSetIndex: Int?
        var confirmedSetCount: Int?
        var skippedSetCount: Int?
        var phaseDeadlineAt: Nullable<Date>?
        var pendingSuggestedActualMs: Nullable<Int64>?
        var pendingMeasuredElapsedMs: Int64?

        private enum CodingKeys: String, CodingKey {
            case error, phase, status, revision, events, signals, currentExecutionIndex, currentSetIndex
            case confirmedSetCount, skippedSetCount, phaseDeadlineAt, pendingSuggestedActualMs, pendingMeasuredElapsedMs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            phase = try c.decodeIfPresent(Phase.self, forKey: .phase)
            status = try c.decodeIfPresent(SessionStatus.self, forKey: .status)
            revision = try c.decodeIfPresent(Int.self, forKey: .revision)
            events = try c.decodeIfPresent([String].self, forKey: .events)
            signals = try c.decodeIfPresent([String].self, forKey: .signals)
            currentExecutionIndex = try c.decodeIfPresent(Int.self, forKey: .currentExecutionIndex)
            currentSetIndex = try c.decodeIfPresent(Int.self, forKey: .currentSetIndex)
            confirmedSetCount = try c.decodeIfPresent(Int.self, forKey: .confirmedSetCount)
            skippedSetCount = try c.decodeIfPresent(Int.self, forKey: .skippedSetCount)
            phaseDeadlineAt = c.contains(.phaseDeadlineAt) ? try c.decode(Nullable<Date>.self, forKey: .phaseDeadlineAt) : nil
            pendingSuggestedActualMs = c.contains(.pendingSuggestedActualMs) ? try c.decode(Nullable<Int64>.self, forKey: .pendingSuggestedActualMs) : nil
            pendingMeasuredElapsedMs = try c.decodeIfPresent(Int64.self, forKey: .pendingMeasuredElapsedMs)
        }
    }

    /// Present-but-possibly-null JSON value (synthesized `decodeIfPresent` would fold `null` into "absent").
    struct Nullable<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            value = c.decodeNil() ? nil : try c.decode(T.self)
        }
    }

    // MARK: Loading

    static func fixturesDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["CALI_REDUCER_FIXTURES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // <repo>/ios/Packages/CaliDomain/Tests/CaliDomainTests/ReducerFixtureTests.swift → <repo>
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("fixtures/reducer", isDirectory: true)
    }

    static func fixtureFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixturesDirectory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testFixtureDirectoryIsPresentAndNonEmpty() throws {
        let dir = Self.fixturesDirectory()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue,
                      "reducer fixtures not found at \(dir.path); mount the repo root or set CALI_REDUCER_FIXTURES_DIR")
        XCTAssertGreaterThanOrEqual(try Self.fixtureFiles().count, 5)
    }

    func testAllReducerFixtures() throws {
        let files = try Self.fixtureFiles()
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let fixture: Fixture
            do {
                fixture = try DomainJSON.makeDecoder().decode(Fixture.self, from: Data(contentsOf: file))
            } catch {
                XCTFail("\(file.lastPathComponent): cannot decode: \(error)")
                continue
            }
            run(fixture, file: file.lastPathComponent)
        }
    }

    // MARK: Runner

    private func run(_ fixture: Fixture, file: String) {
        var state: SessionState?
        for (i, step) in fixture.steps.enumerated() {
            let ctx = "\(file) step \(i + 1)"
            XCTAssertTrue((step.command == nil) != (step.reconcile == nil), "\(ctx): exactly one of command/reconcile")

            var events: [DomainEvent] = []
            var signals: [ReconcileSignal] = []
            var error: DomainError?

            if let command = step.command {
                switch WorkoutReducer.reduce(state, command, now: step.now) {
                case .success(let t):
                    state = t.state
                    events = t.events
                case .failure(let e):
                    error = e
                }
            } else if let r = step.reconcile {
                guard let current = state else { XCTFail("\(ctx): reconcile without session"); return }
                let result = WorkoutReducer.reconcile(
                    current, now: step.now, previousNow: r.previousNow,
                    monotonicElapsed: r.monotonicElapsed, acknowledgeClockJump: r.acknowledgeClockJump ?? false
                )
                state = result.state
                events = result.events
                signals = result.signals
            }

            let e = step.expect
            XCTAssertEqual(error?.code, e.error, "\(ctx): error (\(String(describing: error)))")
            if let s = state {
                XCTAssertEqual(s.invariantViolations, [], "\(ctx): invariants")
            }
            if let v = e.events { XCTAssertEqual(events.map(\.code), v, "\(ctx): events") }
            if let v = e.signals { XCTAssertEqual(signals.map(\.code), v, "\(ctx): signals") }
            guard let s = state else {
                XCTAssertNil(e.phase, "\(ctx): no session but phase expected")
                continue
            }
            if let v = e.phase { XCTAssertEqual(s.phase, v, "\(ctx): phase") }
            if let v = e.status { XCTAssertEqual(s.status, v, "\(ctx): status") }
            if let v = e.revision { XCTAssertEqual(s.revision, v, "\(ctx): revision") }
            if let v = e.currentExecutionIndex { XCTAssertEqual(s.currentExecutionIndex, v, "\(ctx): currentExecutionIndex") }
            if let v = e.currentSetIndex { XCTAssertEqual(s.currentSetIndex, v, "\(ctx): currentSetIndex") }
            if let v = e.confirmedSetCount { XCTAssertEqual(s.confirmedSetCount, v, "\(ctx): confirmedSetCount") }
            if let v = e.skippedSetCount { XCTAssertEqual(s.skippedSetCount, v, "\(ctx): skippedSetCount") }
            if let v = e.phaseDeadlineAt { XCTAssertEqual(s.phaseDeadlineAt, v.value, "\(ctx): phaseDeadlineAt") }
            if let v = e.pendingSuggestedActualMs { XCTAssertEqual(s.pendingResult?.suggestedActualMs, v.value, "\(ctx): suggestedActualMs") }
            if let v = e.pendingMeasuredElapsedMs { XCTAssertEqual(s.pendingResult?.measuredElapsedMs, v, "\(ctx): measuredElapsedMs") }
        }
    }
}
