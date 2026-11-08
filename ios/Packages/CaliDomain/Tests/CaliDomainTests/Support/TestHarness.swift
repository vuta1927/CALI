import CaliDomain
import CaliDomainTestSupport
import Foundation
import XCTest

/// Deterministic UUID `00000000-0000-4000-8000-<n padded to 12>`.
func uuid(_ n: Int) -> UUID {
    let digits = String(n)
    let padded = String(repeating: "0", count: max(0, 12 - digits.count)) + digits
    return UUID(uuidString: "00000000-0000-4000-8000-\(padded)")!
}

let t0 = DomainJSON.date("2026-11-07T08:00:00Z")!

enum Specs {
    static let holdId = uuid(9001)
    static let repsId = uuid(9002)

    /// Static hold 12s x 2 sets, 90s rest.
    static func hold(sets: Int = 2, holdSeconds: Int = 12, rest: Int = 90, id: UUID = holdId) -> ExecutionSpec {
        ExecutionSpec(id: id, plannedExerciseId: uuid(8001), exerciseId: uuid(7001), catalogVersion: 3, setCount: sets, target: .staticHold(holdSeconds: holdSeconds), restSeconds: rest)
    }

    /// Reps 8-10 x 2 sets, 120s rest.
    static func reps(sets: Int = 2, rest: Int = 120, id: UUID = repsId) -> ExecutionSpec {
        ExecutionSpec(id: id, plannedExerciseId: uuid(8002), exerciseId: uuid(7002), catalogVersion: 1, setCount: sets, target: .reps(repMin: 8, repMax: 10), restSeconds: rest)
    }
}

/// Drives the pure reducer with a `FakeClock`, asserting after every accepted transition that
/// invariants hold and the revision increased by exactly one per step; after every rejection that
/// the state is untouched.
final class Harness {
    let clock: FakeClock
    private(set) var state: SessionState?
    private var nextId = 1
    let file: StaticString
    let line: UInt

    init(start: Date = t0, file: StaticString = #filePath, line: UInt = #line) {
        clock = FakeClock(now: start)
        self.file = file
        self.line = line
    }

    var s: SessionState { state! }
    var now: Date { clock.now() }

    func freshId() -> UUID {
        defer { nextId += 1 }
        return uuid(nextId)
    }

    @discardableResult
    func send(_ command: Command, file: StaticString = #filePath, line: UInt = #line) -> Transition {
        let before = state
        switch WorkoutReducer.reduce(state, command, now: clock.now()) {
        case .success(let t):
            XCTAssertEqual(t.state.invariantViolations, [], "invariants after \(command.kind)", file: file, line: line)
            if let before, before.sessionId == t.state.sessionId {
                XCTAssertEqual(t.state.revision, before.revision + 1, "revision must bump by 1", file: file, line: line)
            } else {
                XCTAssertEqual(t.state.revision, 1, file: file, line: line)
            }
            XCTAssertEqual(t.state.updatedAt, clock.now(), file: file, line: line)
            state = t.state
            return t
        case .failure(let e):
            XCTFail("unexpected \(e) for \(command.kind) in \(state?.phase.rawValue ?? "nil")", file: file, line: line)
            return Transition(state: before!, events: [])
        }
    }

    @discardableResult
    func reject(_ command: Command, file: StaticString = #filePath, line: UInt = #line) -> DomainError? {
        switch WorkoutReducer.reduce(state, command, now: clock.now()) {
        case .success(let t):
            XCTFail("expected rejection of \(command.kind) in \(state?.phase.rawValue ?? "nil"), got \(t.state.phase)", file: file, line: line)
            return nil
        case .failure(let e):
            return e
        }
    }

    @discardableResult
    func reconcile(previousNow: Date? = nil, monotonicElapsed: TimeInterval? = nil, acknowledge: Bool = false, policy: ReconcilePolicy = .standard, file: StaticString = #filePath, line: UInt = #line) -> ReconcileResult {
        let before = s
        let r = WorkoutReducer.reconcile(before, now: clock.now(), previousNow: previousNow, monotonicElapsed: monotonicElapsed, acknowledgeClockJump: acknowledge, policy: policy)
        XCTAssertEqual(r.state.invariantViolations, [], "invariants after reconcile", file: file, line: line)
        if r.changed {
            XCTAssertGreaterThan(r.state.revision, before.revision, file: file, line: line)
            XCTAssertEqual(r.state.revision - before.revision, r.events.filter { if case .phaseChanged = $0 { true } else { false } }.count,
                           "one revision per derived phase step", file: file, line: line)
        } else {
            XCTAssertEqual(r.state, before, file: file, line: line)
            XCTAssertEqual(r.events, [], file: file, line: line)
        }
        state = r.state
        return r
    }

    // MARK: Command builders

    func create(_ executions: [ExecutionSpec] = [Specs.hold(), Specs.reps()], sessionId: UUID = uuid(5000)) -> Command {
        .createSession(CreateSession(commandId: freshId(), sessionId: sessionId, plannedWorkoutId: uuid(6000), executions: executions))
    }

    func startSet(countdown: Int = 3) -> Command { .startSet(StartSet(commandId: freshId(), countdownSeconds: countdown)) }
    func pause() -> Command { .pause(SimpleCommand(commandId: freshId())) }
    func resume() -> Command { .resume(SimpleCommand(commandId: freshId())) }
    func stopSet() -> Command { .stopSet(SimpleCommand(commandId: freshId())) }
    func readyNext() -> Command { .readyNext(SimpleCommand(commandId: freshId())) }
    func finish() -> Command { .finishSession(SimpleCommand(commandId: freshId())) }
    func abandon(_ reason: String? = "tired") -> Command { .abandonSession(AbandonSession(commandId: freshId(), reason: reason)) }
    func extendRest(_ seconds: Int = 30) -> Command { .extendRest(ExtendRest(commandId: freshId(), seconds: seconds)) }

    /// Valid confirm payload for the current set and its exercise type.
    func confirm(key: SetKey? = nil, setResultId: UUID? = nil, holdMs: Int64 = 12_000, reps: Int = 9, rpe: Int? = 7) -> Command {
        let k = key ?? s.currentSetKey!
        let target = s.executions.first { $0.id == k.executionId }?.target ?? s.currentExecution!.target
        var c = ConfirmSet(commandId: freshId(), setResultId: setResultId ?? freshId(), executionId: k.executionId, setIndex: k.setIndex, rpe: rpe)
        switch target {
        case .staticHold: c.actualHoldMs = holdMs
        case .reps: c.actualReps = reps
        case .timedReps:
            c.actualReps = reps
            c.actualWorkMs = holdMs
        case .interval: c.actualWorkMs = holdMs
        case .skillAttempt: break
        case .load:
            c.actualReps = reps
            c.actualLoadKg = Decimal(string: "57.5")
        }
        return .confirmSet(c)
    }

    func skip(key: SetKey? = nil, reason: String? = "wrist pain") -> Command {
        let k = key ?? s.currentSetKey!
        return .skipSet(SkipSet(commandId: freshId(), setResultId: freshId(), executionId: k.executionId, setIndex: k.setIndex, reason: reason))
    }

    /// A syntactically valid command of `kind` targeting the current set.
    func command(_ kind: CommandKind) -> Command {
        switch kind {
        case .createSession: create(sessionId: uuid(5999))
        case .startSet: startSet()
        case .pause: pause()
        case .resume: resume()
        case .stopSet: stopSet()
        case .confirmSet: confirm()
        case .extendRest: extendRest()
        case .readyNext: readyNext()
        case .skipSet: skip()
        case .finishSession: finish()
        case .abandonSession: abandon()
        }
    }

    // MARK: Scenario shortcuts (each uses only legal transitions)

    func toReady() { send(create()) }

    func toPreCountdown() { toReady(); send(startSet()) }

    func toExercising() {
        toPreCountdown()
        clock.advance(by: 3)
        reconcile(previousNow: now.addingTimeInterval(-3), monotonicElapsed: 3)
        XCTAssertEqual(s.phase, .exercising, file: file, line: line)
    }

    func toPaused() { toExercising(); clock.advance(by: 4); send(pause()) }

    func toAwaitingResult() { toExercising(); clock.advance(by: 5); send(stopSet()) }

    func toResting() { toAwaitingResult(); send(confirm()) }

    /// Resolve every remaining set via confirm/skip to reach the summary.
    func toReviewingSummary() {
        toReady()
        while s.phase != .reviewingSummary {
            switch s.phase {
            case .ready: send(skip())
            default: XCTFail("unexpected phase \(s.phase)", file: file, line: line); return
            }
        }
    }

    func toCompleted() { toReviewingSummary(); clock.advance(by: 10); send(finish()) }
    func toAbandoned() { toReady(); send(abandon()) }

    func reach(_ phase: Phase) {
        switch phase {
        case .ready: toReady()
        case .preCountdown: toPreCountdown()
        case .exercising: toExercising()
        case .paused: toPaused()
        case .awaitingResult: toAwaitingResult()
        case .resting: toResting()
        case .reviewingSummary: toReviewingSummary()
        case .completed: toCompleted()
        case .abandoned: toAbandoned()
        }
        XCTAssertEqual(s.phase, phase, file: file, line: line)
    }
}

extension Array where Element == DomainEvent {
    var codes: [String] { map(\.code) }
}
