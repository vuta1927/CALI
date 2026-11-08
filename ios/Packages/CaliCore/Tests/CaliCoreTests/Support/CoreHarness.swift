import CaliCore
import CaliDomain
import CaliDomainTestSupport
import Foundation
import GRDB
import XCTest

/// Deterministic UUID `00000000-0000-4000-8000-<n padded to 12>` (same scheme as CaliDomainTests).
func uuid(_ n: Int) -> UUID {
    let digits = String(n)
    let padded = String(repeating: "0", count: max(0, 12 - digits.count)) + digits
    return UUID(uuidString: "00000000-0000-4000-8000-\(padded)")!
}

let t0 = DomainJSON.date("2026-11-07T08:00:00Z")!
let sessionA = uuid(5000)

enum Specs {
    /// Static hold 12s x 2 sets, 90s rest (the POC scenario).
    static func hold(sets: Int = 2, holdSeconds: Int = 12, rest: Int = 90) -> ExecutionSpec {
        ExecutionSpec(id: uuid(9001), plannedExerciseId: uuid(8001), exerciseId: uuid(7001), catalogVersion: 3, setCount: sets,
                      target: .staticHold(holdSeconds: holdSeconds), restSeconds: rest)
    }

    static func reps(sets: Int = 2, rest: Int = 120) -> ExecutionSpec {
        ExecutionSpec(id: uuid(9002), plannedExerciseId: uuid(8002), exerciseId: uuid(7002), catalogVersion: 1, setCount: sets,
                      target: .reps(repMin: 8, repMax: 10), restSeconds: rest)
    }
}

/// Temporary on-disk database directory (WAL needs a real file system; kept under the OS temp dir so it
/// also works when the package itself sits on a Windows bind mount inside Docker).
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("calicore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var dbURL: URL { url.appendingPathComponent("poc-002.sqlite") }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Drives a `WorkoutCoordinator` with a `FakeClock` and fresh command ids.
final class CoreFixture {
    let clock: FakeClock
    let coordinator: WorkoutCoordinator
    private var nextId = 1

    init(writer: any DatabaseWriter, clock: FakeClock = FakeClock(now: t0)) {
        self.clock = clock
        coordinator = WorkoutCoordinator(writer: writer, clock: clock)
    }

    static func inMemory() throws -> CoreFixture { CoreFixture(writer: try CaliDatabase.openInMemory()) }

    func freshId() -> UUID {
        defer { nextId += 1 }
        return uuid(nextId)
    }

    var state: SessionState { try! coordinator.activeState()! }

    @discardableResult
    func send(_ command: Command, file: StaticString = #filePath, line: UInt = #line) throws -> HandleResult {
        let result = try coordinator.handle(command)
        XCTAssertFalse(result.replayed, "unexpected replay of \(command.kind)", file: file, line: line)
        XCTAssertEqual(result.outcome.status, .applied, "\(command.kind) → \(result.outcome.errorCode ?? "-")", file: file, line: line)
        return result
    }

    func create(_ executions: [ExecutionSpec] = [Specs.hold()], sessionId: UUID = sessionA) -> Command {
        .createSession(CreateSession(commandId: freshId(), sessionId: sessionId, plannedWorkoutId: uuid(6000), executions: executions))
    }

    /// Countdown disabled ⇒ straight to exercising with a UTC deadline for timed targets.
    func startSet() -> Command { .startSet(StartSet(commandId: freshId(), countdownSeconds: 0)) }
    func stopSet() -> Command { .stopSet(SimpleCommand(commandId: freshId())) }
    func readyNext() -> Command { .readyNext(SimpleCommand(commandId: freshId())) }
    func extendRest(_ seconds: Int = 30) -> Command { .extendRest(ExtendRest(commandId: freshId(), seconds: seconds)) }

    func confirm(commandId: UUID? = nil, setResultId: UUID? = nil, holdMs: Int64 = 12_000, reps: Int = 9) -> Command {
        let key = state.currentSetKey!
        var c = ConfirmSet(commandId: commandId ?? freshId(), setResultId: setResultId ?? freshId(), executionId: key.executionId, setIndex: key.setIndex)
        switch state.currentExecution!.target {
        case .staticHold: c.actualHoldMs = holdMs
        case .reps: c.actualReps = reps
        case .timedReps:
            c.actualReps = reps
            c.actualWorkMs = holdMs
        case .interval: c.actualWorkMs = holdMs
        case .skillAttempt: break
        }
        return .confirmSet(c)
    }

    // MARK: Scenario shortcuts

    func toExercising(_ executions: [ExecutionSpec] = [Specs.hold()]) throws {
        try send(create(executions))
        try send(startSet())
        XCTAssertEqual(state.phase, .exercising)
    }

    /// Hold deadline reached while the app runs: reconcile promptly ⇒ draft with suggested actual.
    func toAwaitingAfterDeadline() throws {
        try toExercising()
        clock.advance(by: 12)
        let r = try coordinator.reconcile(previousNow: clock.now().addingTimeInterval(-12), monotonicElapsed: 12)
        XCTAssertEqual(r?.changed, true)
        XCTAssertEqual(state.phase, .awaitingResult)
        XCTAssertEqual(state.pendingResult?.suggestedActualMs, 12_000)
    }

    func toAwaitingByStop(_ executions: [ExecutionSpec] = [Specs.hold()], after seconds: TimeInterval = 5) throws {
        try toExercising(executions)
        clock.advance(by: seconds)
        try send(stopSet())
        XCTAssertEqual(state.phase, .awaitingResult)
    }

    func toResting() throws {
        try toAwaitingByStop()
        try send(confirm(holdMs: 5_000))
        XCTAssertEqual(state.phase, .resting)
    }
}

/// Thread-safe collector for results produced inside `DispatchQueue.concurrentPerform`.
final class Collector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}
