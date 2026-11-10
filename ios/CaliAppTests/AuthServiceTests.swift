import AuthenticationServices
import CaliCore
import XCTest
@testable import CaliApp

/// IOS-008 with fake tokens: TODO(BE-004-APPLE) verify against a real Apple identity token when a paid account exists.
@MainActor
final class AuthServiceTests: XCTestCase {
    private let userA = UUID(uuidString: "0a0a0a0a-0000-4000-8000-00000000000a")!
    private let userB = UUID(uuidString: "0b0b0b0b-0000-4000-8000-00000000000b")!
    private let base = URL(string: "https://api.example.invalid/")!

    private func make(baseURL: URL? = URL(string: "https://api.example.invalid/")!, api: FakeAuthAPI = FakeAuthAPI(), store: MemorySessionStore = MemorySessionStore(),
                      database: AppDatabase? = nil) throws -> (AuthService, FakeAuthAPI, MemorySessionStore, AppDatabase) {
        let database = try database ?? AppDatabase.inMemory()
        return (AuthService(coordinator: database.coordinator, baseURL: baseURL, api: api, store: store), api, store, database)
    }

    private func signIn(_ auth: AuthService, as user: UUID, _ api: FakeAuthAPI) async {
        api.user = user
        auth.prepare(ASAuthorizationAppleIDProvider().createRequest())
        await auth.finishSignIn(identityToken: "apple.identity.token")
    }

    func testWithoutAServerAddressTheButtonIsUnavailableAndNothingSyncs() throws {
        let (auth, _, _, _) = try make(baseURL: nil)
        XCTAssertFalse(auth.isAvailable)
        XCTAssertFalse(auth.allowsSync)
        XCTAssertEqual(auth.state, .signedOut)
    }

    func testRequestAsksForNoScopesAndHashesTheRawNonceTheApiReceives() async throws {
        let (auth, api, _, _) = try make()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        auth.prepare(request)
        XCTAssertEqual(request.requestedScopes ?? [], [], "no name or e-mail")
        let hashed = try XCTUnwrap(request.nonce)
        await auth.finishSignIn(identityToken: "apple.identity.token")
        XCTAssertEqual(AppleNonce.hashed(try XCTUnwrap(api.nonces.first)), hashed, "Apple got the hash, the API got the raw string")
        await auth.finishSignIn(identityToken: "apple.identity.token")
        XCTAssertEqual(api.nonces.count, 1, "a nonce works once")
    }

    func testFirstSignInAsksBeforeAnythingSyncsThenAttachStartsSync() async throws {
        let (auth, api, store, _) = try make()
        var changes = 0
        auth.onSessionChanged = { changes += 1 }
        await signIn(auth, as: userA, api)
        XCTAssertEqual(auth.state, .choosingAttach)
        XCTAssertFalse(auth.allowsSync, "sync waits for the answer")
        XCTAssertEqual(changes, 0)
        XCTAssertNotNil(try store.load(), "the session is already kept")

        auth.chooseAttach(true)
        XCTAssertEqual(auth.state, .signedIn(name: "Vu"))
        XCTAssertTrue(auth.allowsSync)
        XCTAssertEqual(changes, 1)
    }

    func testSameAccountAgainSkipsTheQuestion() async throws {
        let (auth, api, _, database) = try make()
        await signIn(auth, as: userA, api)
        auth.chooseAttach(false)
        await auth.endSession()
        XCTAssertEqual(auth.state, .signedOut)

        let again = AuthService(coordinator: database.coordinator, baseURL: base, api: api, store: MemorySessionStore())
        await signIn(again, as: userA, api)
        XCTAssertEqual(again.state, .signedIn(name: "Vu"))
    }

    func testAnotherAccountIsRefusedWhileTheFirstOnesDataIsOnThePhone() async throws {
        let (auth, api, store, database) = try make()
        await signIn(auth, as: userA, api)
        auth.chooseAttach(true)
        await auth.endSession()

        let second = AuthService(coordinator: database.coordinator, baseURL: base, api: api, store: store)
        await signIn(second, as: userB, api)
        XCTAssertEqual(second.state, .signedOut)
        XCTAssertFalse(second.allowsSync)
        XCTAssertNil(try store.load(), "no tokens held for an account that may not touch this data")
        XCTAssertTrue(second.message?.contains("tài khoản khác") == true)
    }

    func testRefusedSignInShowsOurSentenceNotTheServers() async throws {
        let (auth, api, _, _) = try make()
        api.fail = SyncTransportError.unauthorized
        await signIn(auth, as: userA, api)
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertEqual(auth.message, "Máy chủ không xác nhận lần đăng nhập này. Thử lại.")
        api.fail = SyncTransportError.offline
        await signIn(auth, as: userA, api)
        XCTAssertEqual(auth.message, "Không kết nối được máy chủ. Dữ liệu trên máy vẫn nguyên vẹn.")
    }

    func testRestoreAfterAnInterruptedSignInAsksAgain() async throws {
        let (first, api, store, database) = try make()
        await signIn(first, as: userA, api) // killed before the answer
        let relaunched = AuthService(coordinator: database.coordinator, baseURL: base, api: api, store: store)
        await relaunched.restore()
        XCTAssertEqual(relaunched.state, .choosingAttach)
        XCTAssertFalse(relaunched.allowsSync)
        relaunched.chooseAttach(true)
        let next = AuthService(coordinator: database.coordinator, baseURL: base, api: api, store: store)
        await next.restore()
        XCTAssertEqual(next.state, .signedIn(name: "Vu"))
    }

    func testSignOutForgetsTheTokens() async throws {
        let (auth, api, store, _) = try make()
        await signIn(auth, as: userA, api)
        auth.chooseAttach(true)
        await auth.endSession()
        XCTAssertNil(try store.load())
        XCTAssertFalse(auth.allowsSync)
    }

    func testSyncIsConfiguredOnlyOnceTheAccountOwnsTheData() async throws {
        let (auth, api, _, database) = try make()
        let sync = SyncService(coordinator: database.coordinator, auth: auth)
        XCTAssertFalse(sync.isConfigured)
        await signIn(auth, as: userA, api)
        sync.reconfigure()
        XCTAssertFalse(sync.isConfigured, "still waiting for the attach answer")
        auth.chooseAttach(true)
        sync.reconfigure()
        XCTAssertTrue(sync.isConfigured)
        await sync.stopAndWait()
        XCTAssertFalse(sync.isConfigured)
    }

    /// Needs the Keychain, which an unsigned simulator build does not have: runs on the signed device build.
    func testKeychainStoreRoundTripsOnlyTheNewestSession() throws {
        let store = KeychainSessionStore(service: "cali.session.test.\(UUID().uuidString)")
        defer { try? store.clear() }
        let first = StoredSession(accessToken: "a1", accessExpiresAt: Date(timeIntervalSince1970: 1_700_000_900), refreshToken: "r1", userId: userA, displayName: nil, deviceId: nil)
        do { try store.save(first) } catch { throw XCTSkip("Keychain unavailable in this build (unsigned simulator): \(error)") }
        XCTAssertEqual(try store.load(), first)
        var second = first
        second.refreshToken = "r2"
        try store.save(second)
        XCTAssertEqual(try store.load()?.refreshToken, "r2")
        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testSignOutSentencesMentionWhatIsLost() {
        XCTAssertTrue(AccountView.signOutMessage(pending: 3, workoutActive: true).contains("3 thay đổi chưa gửi"))
        XCTAssertTrue(AccountView.signOutMessage(pending: 3, workoutActive: true).contains("Buổi tập đang dở"))
        XCTAssertFalse(AccountView.signOutMessage(pending: 0, workoutActive: false).contains("mất"))
    }
}

private final class FakeAuthAPI: AuthAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    var user = UUID()
    var fail: (any Error)?
    var nonces: [String] { lock.withLock { seen } }

    func signInWithApple(identityToken: String, nonce: String, deviceId: UUID?) async throws -> AuthTokens {
        lock.withLock { seen.append(nonce) }
        if let fail { throw fail }
        return tokens()
    }

    func refresh(refreshToken: String, deviceId: UUID?) async throws -> AuthTokens { tokens() }

    private func tokens() -> AuthTokens {
        AuthTokens(accessToken: "access", refreshToken: "refresh", expiresInSeconds: 900,
                   user: UserProfile(id: user, displayName: "Vu", timezone: "Asia/Bangkok", createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
    }
}

private final class MemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredSession?
    func load() throws -> StoredSession? { lock.withLock { value } }
    func save(_ session: StoredSession) throws { lock.withLock { value = session } }
    func clear() throws { lock.withLock { value = nil } }
}

/// The real app starts with no bundled plan, history or catalog; the catalog comes from the server.
@MainActor
final class ServerOnlyStartTests: XCTestCase {
    func testStartsEmpty() throws {
        let store = AppStore(persists: false, starterContent: false)
        XCTAssertTrue(store.plans.isEmpty)
        XCTAssertTrue(store.catalog.isEmpty)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertTrue(store.recommendations.isEmpty)
    }

    func testClearLocalDataLeavesNothingBehind() throws {
        let store = AppStore(persists: false)
        XCTAssertFalse(store.plans.isEmpty)
        store.clearLocalData()
        XCTAssertTrue(store.plans.isEmpty)
        XCTAssertTrue(store.catalog.isEmpty)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertTrue(store.recommendations.isEmpty)
        XCTAssertTrue(store.weightEntries.isEmpty)
        XCTAssertEqual(store.sync.status.pending, 0)
    }

    func testClearMessageNamesWhatIsLost() {
        XCTAssertTrue(ProfileView.clearMessage(pending: 2, workoutActive: true).contains("2 thay đổi chưa gửi"))
        XCTAssertTrue(ProfileView.clearMessage(pending: 0, workoutActive: false).contains("Không thể hoàn tác"))
    }
}
