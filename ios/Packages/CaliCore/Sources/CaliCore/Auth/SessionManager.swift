import Foundation

/// What is kept between launches (Keychain, this device only). Never printed.
public struct StoredSession: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String
    public var accessExpiresAt: Date
    /// Only the newest one is kept: a spent refresh token revokes the whole session (ADR-071).
    public var refreshToken: String
    public var userId: UUID
    public var displayName: String?
    /// The sync device id the session was started with; refreshes send this one even if the sync id changes later.
    public var deviceId: UUID?

    public init(accessToken: String, accessExpiresAt: Date, refreshToken: String, userId: UUID, displayName: String?, deviceId: UUID?) {
        self.accessToken = accessToken
        self.accessExpiresAt = accessExpiresAt
        self.refreshToken = refreshToken
        self.userId = userId
        self.displayName = displayName
        self.deviceId = deviceId
    }

    public var description: String { "StoredSession(user: \(userId), ‹redacted›)" }
    public var debugDescription: String { description }
}

/// Persistence of the session. The app's implementation is the Keychain.
public protocol SessionStore: Sendable {
    func load() throws -> StoredSession?
    func save(_ session: StoredSession) throws
    func clear() throws
}

/// Session life of one account on this device: sign in, keep the access token fresh, rotate the refresh token, sign out.
///
/// - Refreshes run one at a time: callers that arrive while one is in flight wait for it and share its result, because a
///   second use of a refresh token revokes the session (docs/08 §6).
/// - The newest tokens are kept in memory first and then saved; if saving fails the session still works until the app
///   quits (then the user signs in again, nothing is lost locally).
/// - A refresh the server refuses (401) ends the session; a network failure does not (the token was not spent if the request
///   never arrived, and nothing here decides otherwise).
/// - Sign-out forgets the tokens. There is no server-side sign-out yet (docs/08 §6).
public actor SessionManager: SyncTokenProvider {
    public enum State: Equatable, Sendable {
        case signedOut
        case signedIn(userId: UUID, displayName: String?)
    }

    private let api: any AuthAPI
    private let store: any SessionStore
    private let clock: @Sendable () -> Date
    private let leeway: TimeInterval
    private var session: StoredSession?
    private var loaded = false
    private var inFlight: Task<Void, any Error>?

    public init(api: any AuthAPI, store: any SessionStore, clock: @escaping @Sendable () -> Date = { Date() }, leeway: TimeInterval = 60) {
        self.api = api
        self.store = store
        self.clock = clock
        self.leeway = leeway
    }

    public func state() -> State {
        loadIfNeeded()
        return session.map { .signedIn(userId: $0.userId, displayName: $0.displayName) } ?? .signedOut
    }

    public func signIn(identityToken: String, rawNonce: String, deviceId: UUID?) async throws -> UserProfile {
        let tokens = try await api.signInWithApple(identityToken: identityToken, nonce: rawNonce, deviceId: deviceId)
        adopt(tokens, deviceId: deviceId)
        return tokens.user
    }

    public func signOut() {
        inFlight?.cancel()
        inFlight = nil
        session = nil
        loaded = true
        try? store.clear()
    }

    // MARK: SyncTokenProvider

    public func accessToken() async throws -> String {
        loadIfNeeded()
        guard let current = session else { throw SyncTransportError.unauthorized }
        if current.accessExpiresAt.timeIntervalSince(clock()) <= leeway { try await refreshAccessToken() }
        guard let fresh = session else { throw SyncTransportError.unauthorized }
        return fresh.accessToken
    }

    public func refreshAccessToken() async throws {
        loadIfNeeded()
        if let inFlight { return try await inFlight.value }
        guard let current = session else { throw SyncTransportError.unauthorized }
        let api = self.api
        let task = Task { () throws -> Void in
            let tokens = try await api.refresh(refreshToken: current.refreshToken, deviceId: current.deviceId)
            try Task.checkCancellation() // signed out meanwhile: do not bring the session back
            self.adopt(tokens, deviceId: current.deviceId)
        }
        inFlight = task
        defer { inFlight = nil }
        do {
            try await task.value
        } catch SyncTransportError.unauthorized {
            session = nil // refused: spent, expired or revoked. The user signs in again.
            try? store.clear()
            throw SyncTransportError.unauthorized
        }
    }

    // MARK: Private

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        session = try? store.load()
    }

    private func adopt(_ tokens: AuthTokens, deviceId: UUID?) {
        let next = StoredSession(accessToken: tokens.accessToken, accessExpiresAt: clock().addingTimeInterval(TimeInterval(tokens.expiresInSeconds)),
                                 refreshToken: tokens.refreshToken, userId: tokens.user.id, displayName: tokens.user.displayName, deviceId: deviceId)
        session = next
        loaded = true
        try? store.save(next)
    }
}
