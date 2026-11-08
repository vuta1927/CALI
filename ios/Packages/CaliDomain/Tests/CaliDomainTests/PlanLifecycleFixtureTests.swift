import CaliDomain
import Foundation
import XCTest

/// Runs the IOS-011 vectors in `<repo>/fixtures/plan-lifecycle/*.json` (running and pace, plan status,
/// current week, missed sessions, active-plan limit, reminder selection).
///
/// Like the reducer vectors, they are read from the repository tree so other implementations can use the same
/// files. Location: `CALI_PLAN_LIFECYCLE_FIXTURES_DIR` if set, else relative to this source file. A missing
/// directory fails the run; it is never skipped.
final class PlanLifecycleFixtureTests: XCTestCase {
    // MARK: Loading

    static func fixturesDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["CALI_PLAN_LIFECYCLE_FIXTURES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // <repo>/ios/Packages/CaliDomain/Tests/CaliDomainTests/PlanLifecycleFixtureTests.swift → <repo>
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("fixtures/plan-lifecycle", isDirectory: true)
    }

    func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = Self.fixturesDirectory().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("plan-lifecycle fixture not found at \(url.path); mount the repo root or set CALI_PLAN_LIFECYCLE_FIXTURES_DIR")
            throw CocoaError(.fileNoSuchFile)
        }
        return try DomainJSON.makeDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    func testFixtureDirectoryHasAllFiles() throws {
        let dir = Self.fixturesDirectory()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(names, ["active_plan_limit.json", "current_week.json", "missed_sessions.json",
                               "notification_selection.json", "plan_status.json", "running_pace.json"])
    }

    struct IssueExpect: Decodable, Equatable, CustomStringConvertible {
        let field: String
        let reason: String
        var description: String { "\(field):\(reason)" }
    }

    func issues(_ list: [ValidationIssue]) -> [IssueExpect] {
        list.map { IssueExpect(field: $0.field, reason: $0.reason.rawValue) }
    }

    // MARK: running_pace.json

    struct RunningFile: Decodable {
        struct PaceCase: Decodable {
            struct Expect: Decodable {
                let roundedSecondsPerKilometer: Int?
                let formatted: String?
                let error: IssueExpect?
            }
            let name: String
            let distanceMeters: Int
            let durationSeconds: Int
            let expect: Expect
        }
        struct KmCase: Decodable {
            let distanceMeters: Int
            let expect: String
        }
        struct TargetCase: Decodable {
            let name: String
            let target: RunningTarget
            let expect: [IssueExpect]
        }
        struct ResultCase: Decodable {
            let name: String
            let snapshotTargetKind: String
            let isCompleted: Bool
            let distanceMeters: Int?
            let durationSeconds: Int?
            let expect: [IssueExpect]
        }
        let pace: [PaceCase]
        let kilometers: [KmCase]
        let targets: [TargetCase]
        let results: [ResultCase]
    }

    func testRunningAndPaceVectors() throws {
        let file = try load("running_pace.json", as: RunningFile.self)
        XCTAssertFalse(file.pace.isEmpty)
        for c in file.pace {
            switch Pace.derive(distanceMeters: c.distanceMeters, durationSeconds: c.durationSeconds) {
            case .success(let pace):
                XCTAssertNil(c.expect.error, "\(c.name): expected an error, got \(pace.formatted)")
                XCTAssertEqual(pace.roundedSecondsPerKilometer, c.expect.roundedSecondsPerKilometer, c.name)
                XCTAssertEqual(pace.formatted, c.expect.formatted, c.name)
            case .failure(let issue):
                XCTAssertEqual(issues([issue]).first, c.expect.error, c.name)
            }
        }
        for c in file.kilometers {
            XCTAssertEqual(RunningFormat.kilometers(distanceMeters: c.distanceMeters), c.expect, "\(c.distanceMeters) m")
        }
        for c in file.targets {
            XCTAssertEqual(issues(c.target.validate()), c.expect, c.name)
        }
        for c in file.results {
            let result = RunningResult(distanceMeters: c.distanceMeters, durationSeconds: c.durationSeconds)
            XCTAssertEqual(issues(result.validate(snapshotTargetKind: c.snapshotTargetKind, isCompleted: c.isCompleted)), c.expect, c.name)
        }
    }

    func testRunningTargetCodableRoundTripAndUnknownKind() throws {
        let targets: [RunningTarget] = [.distance(distanceMeters: 1000, durationSeconds: 290),
                                        .distance(distanceMeters: 5000, durationSeconds: nil),
                                        .duration(durationSeconds: 1800)]
        for target in targets {
            let data = try JSONEncoder().encode(target)
            XCTAssertEqual(try JSONDecoder().decode(RunningTarget.self, from: data), target)
        }
        let open = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RunningTarget.distance(distanceMeters: 5000, durationSeconds: nil))) as? [String: Any]
        XCTAssertNil(open?["durationSeconds"], "an absent goal time is omitted, not null")
        XCTAssertThrowsError(try JSONDecoder().decode(RunningTarget.self, from: Data(#"{"kind":"reps","durationSeconds":10}"#.utf8)))
    }

    func testPaceExactValue() throws {
        let pace = try Pace.derive(distanceMeters: 8250, durationSeconds: 2470).get()
        XCTAssertEqual(pace.secondsPerKilometer, 2470.0 / 8.25, accuracy: 1e-9)
        XCTAssertEqual(pace.roundedSecondsPerKilometer, 299)
    }

    // MARK: plan_status.json

    struct StatusFile: Decodable {
        struct StatusCase: Decodable {
            struct Expect: Decodable {
                let status: PlanStatus
                let countsTowardActiveLimit: Bool
            }
            let name: String
            let today: LocalDate
            let plan: PlanLineageState
            let expect: Expect
        }
        struct RuleCase: Decodable {
            let name: String
            let now: Date
            let activation: PlanActivation
            let existing: [PlanActivation]
            let expect: [IssueExpect]
        }
        let cases: [StatusCase]
        let activationRules: [RuleCase]
    }

    func testPlanStatusVectors() throws {
        let file = try load("plan_status.json", as: StatusFile.self)
        XCTAssertFalse(file.cases.isEmpty)
        for c in file.cases {
            let status = PlanLifecycle.status(of: c.plan, today: c.today)
            XCTAssertEqual(status, c.expect.status, c.name)
            XCTAssertEqual(status.countsTowardActiveLimit, c.expect.countsTowardActiveLimit, c.name)
        }
        for c in file.activationRules {
            XCTAssertEqual(issues(PlanLifecycle.validateNewActivation(c.activation, existing: c.existing, now: c.now)), c.expect, c.name)
        }
        // plansTakingSlots agrees with the per-plan statuses.
        let today = LocalDate("2026-11-09")!
        let expected = file.cases.filter { $0.today == today && $0.expect.countsTowardActiveLimit }.map(\.plan)
        let all = file.cases.filter { $0.today == today }.map(\.plan)
        XCTAssertEqual(PlanLifecycle.plansTakingSlots(all, today: today).count, expected.count)
    }

    func testOverlappingActivationsI1() {
        let a = PlanActivation(id: uuid(11), fromDate: LocalDate("2026-11-02")!, toDate: LocalDate("2026-11-05")!, timezone: "UTC")
        let b = PlanActivation(id: uuid(12), fromDate: LocalDate("2026-11-06")!, toDate: LocalDate("2026-11-08")!, timezone: "UTC")
        let c = PlanActivation(id: uuid(13), fromDate: LocalDate("2026-11-08")!, timezone: "UTC")
        let d = PlanActivation(id: uuid(14), fromDate: LocalDate("2026-11-20")!, timezone: "UTC")
        let pairs = PlanLifecycle.overlappingActivations([a, b, c, d])
        XCTAssertEqual(pairs.map { [$0.0, $0.1] }, [[uuid(12), uuid(13)], [uuid(13), uuid(14)]])
        XCTAssertTrue(PlanLifecycle.overlappingActivations([a, b]).isEmpty, "adjacent ranges do not overlap")
    }

    // MARK: current_week.json

    struct WeekFile: Decodable {
        struct WeekCase: Decodable {
            struct Expect: Decodable {
                let state: CurrentWeek.State
                let week: Int
                let dayInWeek: Int?
                let elapsedDays: Int
                let daysUntilEvent: Int?
            }
            let name: String
            let today: LocalDate
            let program: PlanProgram
            let activations: [PlanActivation]
            let expect: Expect
        }
        let cases: [WeekCase]
    }

    func testCurrentWeekVectors() throws {
        let file = try load("current_week.json", as: WeekFile.self)
        XCTAssertFalse(file.cases.isEmpty)
        for c in file.cases {
            let e = c.expect
            XCTAssertEqual(PlanSchedule.currentWeek(program: c.program, activations: c.activations, today: c.today),
                           CurrentWeek(state: e.state, week: e.week, dayInWeek: e.dayInWeek, elapsedDays: e.elapsedDays, daysUntilEvent: e.daysUntilEvent),
                           c.name)
        }
    }

    // MARK: missed_sessions.json

    struct MissedFile: Decodable {
        struct MissedCase: Decodable {
            struct Occurrence: Decodable, Equatable {
                let plannedWorkoutId: UUID
                let originalDate: LocalDate
                let date: LocalDate
                let outcome: PlannedOccurrence.Outcome
                let sessionId: UUID?
            }
            struct Expect: Decodable {
                let completed: Int
                let missed: Int
                let pending: Int
                let occurrences: [Occurrence]
            }
            let name: String
            let lineageId: UUID
            let today: LocalDate
            let program: PlanProgram
            let activations: [PlanActivation]
            let slots: [WeeklySlot]
            let reschedules: [Reschedule]
            let sessions: [CompletedSessionRef]
            let expect: Expect
        }
        let cases: [MissedCase]
    }

    func testMissedSessionVectors() throws {
        let file = try load("missed_sessions.json", as: MissedFile.self)
        XCTAssertFalse(file.cases.isEmpty)
        for c in file.cases {
            let result = PlanSchedule.adherence(lineageId: c.lineageId, program: c.program, activations: c.activations, slots: c.slots,
                                                reschedules: c.reschedules, sessions: c.sessions, today: c.today)
            let actual = result.occurrences.map {
                MissedFile.MissedCase.Occurrence(plannedWorkoutId: $0.plannedWorkoutId, originalDate: $0.originalDate, date: $0.date,
                                                 outcome: $0.outcome, sessionId: $0.sessionId)
            }
            XCTAssertEqual(actual, c.expect.occurrences, c.name)
            XCTAssertEqual(result.completedCount, c.expect.completed, c.name)
            XCTAssertEqual(result.missedCount, c.expect.missed, c.name)
            XCTAssertEqual(result.pendingCount, c.expect.pending, c.name)
        }
    }

    func testSessionOrderDoesNotChangeAdherence() throws {
        let file = try load("missed_sessions.json", as: MissedFile.self)
        for c in file.cases {
            let forward = PlanSchedule.adherence(lineageId: c.lineageId, program: c.program, activations: c.activations, slots: c.slots,
                                                 reschedules: c.reschedules, sessions: c.sessions, today: c.today)
            let reversed = PlanSchedule.adherence(lineageId: c.lineageId, program: c.program, activations: c.activations, slots: c.slots,
                                                  reschedules: c.reschedules, sessions: c.sessions.reversed(), today: c.today)
            XCTAssertEqual(forward, reversed, c.name)
        }
    }

    func testOccurrencesInFutureWindowIncludeRescheduledIn() {
        let act = PlanActivation(id: uuid(11), fromDate: LocalDate("2026-11-02")!, timezone: "UTC")
        let slots = [WeeklySlot(plannedWorkoutId: uuid(101), weekday: 1)]
        // Monday 11-16 moved back to Saturday 11-14, which is inside a window that does not include 11-16.
        let moved = Reschedule(plannedWorkoutId: uuid(101), originalDate: LocalDate("2026-11-16")!, newDate: LocalDate("2026-11-14")!)
        let list = PlanSchedule.occurrences(program: .weekly(totalWeeks: nil), activations: [act], slots: slots, reschedules: [moved],
                                            from: LocalDate("2026-11-10")!, through: LocalDate("2026-11-15")!)
        XCTAssertEqual(list.map(\.date), [LocalDate("2026-11-14")!])
        XCTAssertEqual(list.map(\.originalDate), [LocalDate("2026-11-16")!])
    }

    // MARK: active_plan_limit.json

    struct LimitFile: Decodable {
        struct LimitCase: Decodable {
            struct Previous: Decodable {
                let lineageId: UUID
                let activation: PlanActivation
            }
            struct Expect: Decodable {
                let result: String
                let day: LocalDate?
                let count: Int?
                let lineageIds: [UUID]?
            }
            let name: String
            let limit: Int
            let candidateLineageId: UUID
            let candidate: PlanActivation
            let previous: Previous?
            let plans: [PlanLineageState]
            let expect: Expect
        }
        let cases: [LimitCase]
    }

    func testActivePlanLimitVectors() throws {
        let file = try load("active_plan_limit.json", as: LimitFile.self)
        XCTAssertFalse(file.cases.isEmpty)
        for c in file.cases {
            let result = PlanLifecycle.checkActivePlanLimit(candidate: c.candidate, candidateLineageId: c.candidateLineageId,
                                                            previous: c.previous.map { (lineageId: $0.lineageId, activation: $0.activation) },
                                                            plans: c.plans, limit: c.limit)
            switch c.expect.result {
            case "allowed":
                XCTAssertEqual(result, .allowed, c.name)
            case "exceedsLimit":
                guard let day = c.expect.day, let count = c.expect.count, let ids = c.expect.lineageIds else {
                    XCTFail("\(c.name): exceedsLimit needs day, count and lineageIds"); continue
                }
                XCTAssertEqual(result, .exceedsLimit(day: day, count: count, limit: c.limit, lineageIds: ids), c.name)
            default:
                XCTFail("\(c.name): unknown result \(c.expect.result)")
            }
        }
        XCTAssertEqual(PlanLifecycle.defaultActivePlanLimit, 3)
        XCTAssertEqual(ActivePlanLimitCheck.errorCode, "active_plan_limit")
    }

    // MARK: notification_selection.json

    struct ReminderFile: Decodable {
        struct ReminderCase: Decodable {
            struct Item: Decodable, Equatable {
                let lineageId: UUID
                let plannedWorkoutId: UUID
            }
            struct Expect: Decodable {
                let fireAt: Date
                let identifier: String?
                let items: [Item]
            }
            let name: String
            let now: Date
            let limit: Int?
            let candidates: [ReminderCandidate]
            let expect: [Expect]
        }
        let cases: [ReminderCase]
    }

    func testReminderSelectionVectors() throws {
        let file = try load("notification_selection.json", as: ReminderFile.self)
        XCTAssertFalse(file.cases.isEmpty)
        for c in file.cases {
            let selected = ReminderSelection.select(c.candidates, now: c.now, limit: c.limit ?? ReminderSelection.systemPendingLimit)
            XCTAssertEqual(selected.map(\.fireAt), c.expect.map(\.fireAt), c.name)
            XCTAssertEqual(selected.map { $0.items.map { ReminderFile.ReminderCase.Item(lineageId: $0.lineageId, plannedWorkoutId: $0.plannedWorkoutId) } },
                           c.expect.map(\.items), c.name)
            for (got, want) in zip(selected, c.expect) {
                if let identifier = want.identifier { XCTAssertEqual(got.identifier, identifier, c.name) }
            }
        }
    }

    func testReminderSelectionCapsAtSixtyFourNearest() {
        let now = DomainJSON.date("2026-11-09T00:00:00Z")!
        // 90 reminders, one per hour, given in reverse order.
        let candidates = (1...90).reversed().map { i in
            ReminderCandidate(lineageId: uuid(1 + i % 3), plannedWorkoutId: uuid(100 + i), fireAt: now.addingTimeInterval(TimeInterval(i * 3600)))
        }
        let selected = ReminderSelection.select(candidates, now: now)
        XCTAssertEqual(ReminderSelection.systemPendingLimit, 64)
        XCTAssertEqual(selected.count, 64)
        XCTAssertEqual(selected.first?.fireAt, now.addingTimeInterval(3600))
        XCTAssertEqual(selected.last?.fireAt, now.addingTimeInterval(64 * 3600))
        XCTAssertEqual(Set(selected.map(\.identifier)).count, 64)
        XCTAssertTrue(ReminderSelection.select(candidates, now: now, limit: 0).isEmpty)
    }

    // MARK: LocalDate

    func testLocalDateParsingArithmeticAndWeekday() throws {
        XCTAssertEqual(LocalDate("2026-11-09")?.isoWeekday, 1)
        XCTAssertEqual(LocalDate("2026-11-15")?.isoWeekday, 7)
        XCTAssertEqual(LocalDate("1970-01-01")?.dayNumber, 0)
        XCTAssertNotNil(LocalDate("2028-02-29"))
        XCTAssertNil(LocalDate("2026-02-29"))
        XCTAssertNil(LocalDate("2100-02-29"))
        XCTAssertNotNil(LocalDate("2000-02-29"))
        XCTAssertNil(LocalDate("2026-11-9"))
        XCTAssertNil(LocalDate("2026-13-01"))
        XCTAssertNil(LocalDate("2026-11-09T00:00:00Z"))
        let d = LocalDate("2026-12-31")!
        XCTAssertEqual(d.adding(days: 1), LocalDate("2027-01-01"))
        XCTAssertEqual(LocalDate("2028-02-28")!.adding(days: 1), LocalDate("2028-02-29"))
        XCTAssertEqual(LocalDate("2026-11-09")!.days(until: LocalDate("2026-12-06")!), 27)
        for n in stride(from: -800_000, through: 800_000, by: 997) {
            XCTAssertEqual(LocalDate(dayNumber: n).dayNumber, n)
        }
        let data = try JSONEncoder().encode([d])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["2026-12-31"]"#)
        XCTAssertEqual(try JSONDecoder().decode([LocalDate].self, from: data), [d])
    }

    func testLocalDateTodayUsesZoneOfInstant() {
        let instant = DomainJSON.date("2026-11-08T17:30:00Z")!
        XCTAssertEqual(LocalDate.today(at: instant, timeZoneIdentifier: "Asia/Ho_Chi_Minh"), LocalDate("2026-11-09"))
        XCTAssertEqual(LocalDate.today(at: instant, timeZoneIdentifier: "UTC"), LocalDate("2026-11-08"))
        XCTAssertEqual(LocalDate.today(at: instant, timeZoneIdentifier: "America/Los_Angeles"), LocalDate("2026-11-08"))
        XCTAssertNil(LocalDate.today(at: instant, timeZoneIdentifier: "Mars/Olympus_Mons"))
    }
}
