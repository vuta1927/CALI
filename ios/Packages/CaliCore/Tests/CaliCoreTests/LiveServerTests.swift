import CaliDomain
import Foundation
import GRDB
import XCTest
@testable import CaliCore

/// IOS-007 against a real test server. Opt-in: set `CALI_LIVE_BASE_URL` and `CALI_LIVE_TOKEN` in the environment (a dev JWT from
/// the backend's `Cali.DevToken`). Without them every test skips, so CI and a plain `swift test` never touch a network.
/// The values are never stored in the repo. Each run writes new synthetic ids (a session of a test user), nothing else.
final class LiveServerTests: XCTestCase {
    private struct Token: SyncTokenProvider {
        let value: String
        func accessToken() async throws -> String { value }
        func refreshAccessToken() async throws { throw SyncTransportError.unauthorized }
    }

    private func api() throws -> URLSessionSyncAPI {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["CALI_LIVE_BASE_URL"], let url = URL(string: base), let token = env["CALI_LIVE_TOKEN"] else { throw XCTSkip("CALI_LIVE_* not set") }
        return URLSessionSyncAPI(baseURL: url, tokens: Token(value: token))
    }

    /// Create, then abandon at once: the server allows one active session per user, so a run must not leave one behind.
    /// Covers the dependency order (session, execution), the terminal upsert rebased on the server version, and the pull cursor.
    func testSessionRoundTripAgainstTheServer() async throws {
        let api = try api()
        let f = try CoreFixture.inMemory()
        var spec = Specs.hold()
        spec.plannedExerciseId = nil // a free workout: no plan row on the server to point at
        try f.send(.createSession(CreateSession(commandId: f.freshId(), sessionId: UUID(), plannedWorkoutId: nil, executions: [spec])))
        try f.send(.abandonSession(AbandonSession(commandId: f.freshId(), reason: "live test")))
        let writer = f.coordinator.writer
        let engine = OutboxSyncEngine(writer: writer, api: api)

        let run = await engine.syncOnce()
        let rows = try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT entity_type, state, error_code FROM sync_outbox ORDER BY seq")
                .map { "\($0["entity_type"] as String) \($0["state"] as String) \(($0["error_code"] as String?) ?? "-")" }
        }
        XCTAssertEqual(rows.first, "workout_session acked -", "\(rows)")
        XCTAssertEqual(rows.last, "workout_session acked -", "the terminal upsert rebased on the server version: \(rows)")
        XCTAssertEqual(run.outcome, .done)
        let cursor = try await writer.read { try String.fetchOne($0, sql: "SELECT cursor FROM sync_cursor WHERE scope = 'main'") }
        XCTAssertNotNil(cursor, "pull saved a cursor")
        // The execution points at a catalog exercise (a foreign key). A server whose catalog is empty rejects it with `validation_failed`.
        if rows[1] != "exercise_execution acked -" { throw XCTSkip("session path verified; execution not accepted (\(rows[1])): the test server needs a seeded exercise catalog") }
    }
}
