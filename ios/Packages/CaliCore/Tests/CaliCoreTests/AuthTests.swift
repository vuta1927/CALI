import CaliCore
import CaliDomain
import CaliDomainTestSupport
import Foundation
import GRDB
import XCTest

/// IOS-008: session life with fake tokens (TODO(BE-004-APPLE): verify against a real Apple token when a paid account exists).
final class AuthTests: XCTestCase {
    // MARK: Nonce

    func testNonceHashIsLowercaseHexSha256() {
        XCTAssertEqual(AppleNonce.hashed("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let raw = AppleNonce.random()
        XCTAssertTrue((8...256).contains(raw.count))
        XCTAssertNotEqual(raw, AppleNonce.random())
        XCTAssertEqual(AppleNonce.hashed(raw).count, 64)
    }

    func testTokensNeverPrintTheirSecrets() {
        let tokens = Fixture.tokens(access: "ACCESS-SECRET", refresh: "REFRESH-SECRET")
        let text = "\(tokens) \(String(reflecting: tokens)) \(Fixture.stored(refresh: "REFRESH-SECRET"))"
        XCTAssertFalse(text.contains("SECRET"))
    }

    // MARK: Sign in and refresh

    func testSignInStoresTokensAndSendsTheDeviceId() async throws {
        let api = FakeAuth()
        let store = MemoryStore()
        let device = UUID()
        let manager = SessionManager(api: api, store: store)
        let user = try await manager.signIn(identityToken: "apple.token", rawNonce: "raw-nonce-1", deviceId: device)
        XCTAssertEqual(user.id, Fixture.userId)
        let calls = api.appleCalls
        XCTAssertEqual(calls.map(\.nonce), ["raw-nonce-1"])
        XCTAssertEqual(calls.first?.deviceId, device)
        XCTAssertEqual(try store.load()?.refreshToken, "refresh-1")
        let state = await manager.state()
        XCTAssertEqual(state, .signedIn(userId: Fixture.userId, displayName: "Vu"))
    }

    func testRelaunchLoadsTheStoredSessionAndRefreshesWhenTheAccessTokenIsAboutToExpire() async throws {
        let clock = TestClock()
        let store = MemoryStore()
        try store.save(Fixture.stored(refresh: "refresh-0", expiresAt: clock.now.addingTimeInterval(30)))
        let api = FakeAuth()
        let manager = SessionManager(api: api, store: store, clock: { clock.now })
        let token = try await manager.accessToken()
        XCTAssertEqual(token, "access-1")
        XCTAssertEqual(api.refreshCalls.map(\.token), ["refresh-0"])
        XCTAssertEqual(api.refreshCalls.first?.deviceId, Fixture.deviceId, "the session's own device id")
        XCTAssertEqual(try store.load()?.refreshToken, "refresh-1", "only the newest refresh token is kept")
    }

    func testAFreshAccessTokenIsNotRefreshed() async throws {
        let clock = TestClock()
        let store = MemoryStore()
        try store.save(Fixture.stored(refresh: "refresh-0", expiresAt: clock.now.addingTimeInterval(600)))
        let api = FakeAuth()
        let manager = SessionManager(api: api, store: store, clock: { clock.now })
        _ = try await manager.accessToken()
        XCTAssertTrue(api.refreshCalls.isEmpty)
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let clock = TestClock()
        let store = MemoryStore()
        try store.save(Fixture.stored(refresh: "refresh-0", expiresAt: clock.now.addingTimeInterval(-5)))
        let api = FakeAuth(delay: 0.2)
        let manager = SessionManager(api: api, store: store, clock: { clock.now })
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<6 { group.addTask { try await manager.accessToken() } }
            var all: [String] = []
            for try await t in group { all.append(t) }
            return all
        }
        XCTAssertEqual(api.refreshCalls.count, 1, "a spent refresh token revokes the session, so one request only")
        XCTAssertEqual(Set(tokens), ["access-1"])
    }

    func testRefusedRefreshEndsTheSession() async throws {
        let clock = TestClock()
        let store = MemoryStore()
        try store.save(Fixture.stored(refresh: "spent", expiresAt: clock.now.addingTimeInterval(-5)))
        let api = FakeAuth(refreshFails: SyncTransportError.unauthorized)
        let manager = SessionManager(api: api, store: store, clock: { clock.now })
        do { _ = try await manager.accessToken(); XCTFail("expected 401") } catch SyncTransportError.unauthorized {}
        let state = await manager.state()
        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(try store.load(), "the dead token is forgotten")
    }

    func testOfflineRefreshKeepsTheSession() async throws {
        let clock = TestClock()
        let store = MemoryStore()
        try store.save(Fixture.stored(refresh: "refresh-0", expiresAt: clock.now.addingTimeInterval(-5)))
        let api = FakeAuth(refreshFails: SyncTransportError.offline)
        let manager = SessionManager(api: api, store: store, clock: { clock.now })
        do { _ = try await manager.accessToken(); XCTFail("expected offline") } catch SyncTransportError.offline {}
        let state = await manager.state()
        XCTAssertEqual(state, .signedIn(userId: Fixture.userId, displayName: "Vu"))
        XCTAssertEqual(try store.load()?.refreshToken, "refresh-0")
    }

    func testSignOutForgetsTheTokensAndNoRefreshComesBack() async throws {
        let clock = TestClock()
        let store = MemoryStore()
        try store.save(Fixture.stored(refresh: "refresh-0", expiresAt: clock.now.addingTimeInterval(-5)))
        let api = FakeAuth(delay: 0.3)
        let manager = SessionManager(api: api, store: store, clock: { clock.now })
        async let pending: String = manager.accessToken()
        try await Task.sleep(nanoseconds: 80_000_000)
        await manager.signOut()
        _ = try? await pending
        let state = await manager.state()
        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(try store.load(), "a refresh that finished after sign-out does not bring the session back")
        do { _ = try await manager.accessToken(); XCTFail("signed out") } catch SyncTransportError.unauthorized {}
    }

    // MARK: HTTP

    func testHttpBodiesAndStatusMapping() async throws {
        typealias Stub = URLSessionSyncAPITests.Stub
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let api = URLSessionAuthAPI(baseURL: URL(string: "https://api.example.test/")!, session: URLSession(configuration: config))
        let device = UUID()
        Stub.seen = []
        Stub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/auth/apple")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            XCTAssertEqual(body?["identityToken"] as? String, "apple.token")
            XCTAssertEqual(body?["nonce"] as? String, "raw-nonce-1")
            XCTAssertEqual((body?["deviceId"] as? String)?.lowercased(), device.uuidString.lowercased())
            return (200, ["Content-Type": "application/json"], Fixture.tokensJSON)
        }
        let tokens = try await api.signInWithApple(identityToken: "apple.token", nonce: "raw-nonce-1", deviceId: device)
        XCTAssertEqual(tokens.refreshToken, "refresh-1")

        for (status, expected) in [(401, "unauthorized"), (429, "rateLimited"), (503, "server")] {
            Stub.handler = { _ in (status, ["Retry-After": "7"], Data()) }
            do { _ = try await api.refresh(refreshToken: "r", deviceId: nil); XCTFail("\(status)") } catch let error as SyncTransportError {
                XCTAssertTrue("\(error)".hasPrefix(expected), "\(status) → \(error)")
            }
        }
    }

    // MARK: Account scope (guest → account, docs/08 §6)

    func testFirstSignInAsksThenBindsAndSameAccountResumes() throws {
        let writer = try CaliDatabase.openInMemory()
        let scope = AccountScope(writer: writer)
        XCTAssertEqual(try scope.check(userId: Fixture.userId), .attachChoiceNeeded)
        try scope.bind(userId: Fixture.userId, attachLocalData: true)
        XCTAssertEqual(try scope.check(userId: Fixture.userId), .ready)
        XCTAssertEqual(try scope.check(userId: UUID()), .otherAccountOnDevice)
        XCTAssertThrowsError(try scope.bind(userId: UUID(), attachLocalData: true), "another account never inherits this data")
    }

    func testKeepingGuestDataOnTheDeviceParksItAndNothingIsPushed() throws {
        let writer = try CaliDatabase.openInMemory()
        try AccountFixtures.seedGuestData(writer)
        let before = try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox WHERE state = 'pending'") ?? 0 }
        XCTAssertGreaterThan(before, 0)
        try AccountScope(writer: writer).bind(userId: Fixture.userId, attachLocalData: false)
        let pending = try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox WHERE state = 'pending'") ?? 0 }
        let dirty = try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM training_plans WHERE dirty = 1") ?? 0 }
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(dirty, 0)
        let parked = try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox WHERE state = 'guest_local'") ?? 0 }
        XCTAssertEqual(parked, before)
    }

    func testAttachingKeepsGuestRowsQueuedWithTheirOwnIds() throws {
        let writer = try CaliDatabase.openInMemory()
        try AccountFixtures.seedGuestData(writer)
        let idsBefore = try writer.read { try String.fetchAll($0, sql: "SELECT entity_id FROM sync_outbox ORDER BY seq") }
        try AccountScope(writer: writer).bind(userId: Fixture.userId, attachLocalData: true)
        let idsAfter = try writer.read { try String.fetchAll($0, sql: "SELECT entity_id FROM sync_outbox WHERE state = 'pending' ORDER BY seq") }
        XCTAssertEqual(idsAfter, idsBefore, "same UUIDs, nothing coalesced by title or date")
    }

    func testSignOutWithDeleteWipesEveryTableThatHoldsPersonalData() throws {
        let writer = try CaliDatabase.openInMemory()
        try AccountFixtures.seedGuestData(writer)
        let scope = AccountScope(writer: writer)
        try scope.bind(userId: Fixture.userId, attachLocalData: true)
        try scope.signOut(deleteLocalData: true, seed: AccountFixtures.seed())
        XCTAssertEqual(try scope.boundAccount(), nil)
        for table in ["body_measurements", "plan_goals", "sync_outbox", "sync_versions", "sync_inbox", "sync_cursor", "session_history", "set_results"] {
            let count = try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 }
            XCTAssertEqual(count, 0, table)
        }
        XCTAssertEqual(try scope.check(userId: UUID()), .attachChoiceNeeded, "a different account can now sign in")
    }

    func testSignOutKeepingDataLeavesItBoundToTheSameAccount() throws {
        let writer = try CaliDatabase.openInMemory()
        try AccountFixtures.seedGuestData(writer)
        let scope = AccountScope(writer: writer)
        try scope.bind(userId: Fixture.userId, attachLocalData: true)
        try scope.signOut(deleteLocalData: false, seed: nil)
        XCTAssertEqual(try scope.check(userId: Fixture.userId), .ready)
        XCTAssertEqual(try scope.check(userId: UUID()), .otherAccountOnDevice)
    }
}

// MARK: Fakes and fixtures

private enum Fixture {
    static let userId = UUID(uuidString: "0a0a0a0a-0000-4000-8000-000000000001")!
    static let deviceId = UUID(uuidString: "0b0b0b0b-0000-4000-8000-000000000002")!
    static let user = UserProfile(id: userId, displayName: "Vu", timezone: "Asia/Bangkok", createdAt: Date(timeIntervalSince1970: 1_700_000_000))

    static func tokens(access: String = "access-1", refresh: String = "refresh-1") -> AuthTokens {
        AuthTokens(accessToken: access, refreshToken: refresh, expiresInSeconds: 900, user: user)
    }

    static func stored(refresh: String, expiresAt: Date = Date(timeIntervalSince1970: 1_700_000_900)) -> StoredSession {
        StoredSession(accessToken: "access-0", accessExpiresAt: expiresAt, refreshToken: refresh, userId: userId, displayName: "Vu", deviceId: deviceId)
    }

    static let tokensJSON = Data("""
    {"accessToken":"access-1","refreshToken":"refresh-1","expiresInSeconds":900,
     "user":{"id":"0a0a0a0a-0000-4000-8000-000000000001","displayName":"Vu","timezone":"Asia/Bangkok","createdAt":"2023-11-14T22:13:20Z"}}
    """.utf8)
}

private final class TestClock: @unchecked Sendable {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
}

private final class MemoryStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredSession?
    func load() throws -> StoredSession? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ session: StoredSession) throws { lock.lock(); value = session; lock.unlock() }
    func clear() throws { lock.lock(); value = nil; lock.unlock() }
}

private final class FakeAuth: AuthAPI, @unchecked Sendable {
    struct Apple { var nonce: String; var deviceId: UUID? }
    struct Refresh { var token: String; var deviceId: UUID? }
    private let lock = NSLock()
    private var apples: [Apple] = []
    private var refreshes: [Refresh] = []
    let delay: TimeInterval
    let refreshFails: (any Error)?

    init(delay: TimeInterval = 0, refreshFails: (any Error)? = nil) {
        self.delay = delay
        self.refreshFails = refreshFails
    }

    var appleCalls: [Apple] { lock.withLock { apples } }
    var refreshCalls: [Refresh] { lock.withLock { refreshes } }

    func signInWithApple(identityToken: String, nonce: String, deviceId: UUID?) async throws -> AuthTokens {
        lock.withLock { apples.append(Apple(nonce: nonce, deviceId: deviceId)) }
        return Fixture.tokens()
    }

    func refresh(refreshToken: String, deviceId: UUID?) async throws -> AuthTokens {
        lock.withLock { refreshes.append(Refresh(token: refreshToken, deviceId: deviceId)) }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let refreshFails { throw refreshFails }
        return Fixture.tokens()
    }
}

private enum AccountFixtures {
    static func seed() -> ContentSeed {
        ContentSeed(catalog: Content.catalog, plan: Content.plan(), sampleHistory: [], sampleRecommendations: [])
    }

    /// A guest's data: the starter plan edited (queues mutations), one body weight and one goal.
    static func seedGuestData(_ writer: DatabaseQueue) throws {
        let store = ContentStore(writer: writer)
        let utc = TimeZone(identifier: "UTC")!
        try store.seedIfEmpty(seed(), now: t0, timeZone: utc)
        var plan = try XCTUnwrap(store.load().plans.first)
        plan.title = "Giáo án của khách"
        let weight = BodyMeasurement(value: Decimal(string: "72.4")!, measuredAt: t0)
        try store.apply(ContentChange(plans: [plan], bodyMeasurements: [weight]), now: t0)
    }
}
