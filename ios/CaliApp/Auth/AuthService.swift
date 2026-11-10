import AuthenticationServices
import CaliCore
import Foundation
import Observation

/// IOS-008: Sign in with Apple and what it means for the data on this device (docs/08 §6).
///
/// The app is complete without an account (AGENTS: offline-first); signing in only turns sync on. Nothing here runs
/// during a workout. No name or e-mail is requested from Apple. Tokens stay in the Keychain (`KeychainSessionStore`).
///
/// TODO(BE-004-APPLE): the flow is tested with fake tokens only; verify against a real Apple identity token once a paid
/// Apple Developer account exists. Expires when QA-002 runs the real sign-in on a device. The "Sign in with Apple"
/// entitlement (`com.apple.developer.applesignin`) is also added then: a free team cannot sign a build that has it.
@Observable
@MainActor
final class AuthService {
    enum State: Equatable {
        case signedOut
        /// Signed in, but the user has not yet said whether the data already on this device joins the account.
        case choosingAttach
        case signedIn(name: String?)
    }

    private(set) var state: State = .signedOut
    private(set) var isWorking = false
    /// A sentence for the user, never a server message.
    private(set) var message: String?

    let baseURL: URL?
    @ObservationIgnored let manager: SessionManager
    @ObservationIgnored private let scope: AccountScope
    @ObservationIgnored private let identity: SyncDeviceIdentity
    @ObservationIgnored private var rawNonce: String?
    @ObservationIgnored private var pendingUser: UUID?
    @ObservationIgnored private var pendingName: String?
    /// Sync must be reconfigured: the session started, ended or was bound to this device's data.
    @ObservationIgnored var onSessionChanged: (() -> Void)?

    init(coordinator: WorkoutCoordinator, baseURL: URL? = AuthService.configuredBaseURL(),
         api: (any AuthAPI)? = nil, store: any SessionStore = KeychainSessionStore()) {
        self.baseURL = baseURL
        scope = AccountScope(coordinator: coordinator)
        identity = SyncDeviceIdentity(coordinator: coordinator)
        let transport: any AuthAPI = api ?? baseURL.map { URLSessionAuthAPI(baseURL: $0) } ?? UnavailableAuthAPI()
        manager = SessionManager(api: transport, store: store)
    }

    /// True when a server address is configured; without one the sign-in button explains why it cannot work.
    var isAvailable: Bool { baseURL != nil }
    /// Sync may use the session only once the account owns this device's data.
    var allowsSync: Bool { if case .signedIn = state { return true } else { return false } }

    // MARK: Launch

    /// Reads the stored session. Interrupted before the attach choice: the choice is asked again, sync stays off.
    func restore() async {
        guard case let .signedIn(userId, name) = await manager.state() else { state = .signedOut; return }
        await enter(userId: userId, name: name)
    }

    /// After a sync run said the session is gone (refresh refused).
    func sessionMayHaveEnded() async {
        guard allowsSync, case .signedOut = await manager.state() else { return }
        state = .signedOut
        message = "Phiên đăng nhập đã hết hạn. Đăng nhập lại để tiếp tục đồng bộ — dữ liệu trên máy vẫn còn nguyên."
        onSessionChanged?()
    }

    // MARK: Sign in

    /// Called by the Apple button before the sheet opens: no scopes, nonce = SHA-256 hex of a fresh random string (ADR-071).
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        message = nil
        let raw = AppleNonce.random()
        rawNonce = raw
        request.requestedScopes = []
        request.nonce = AppleNonce.hashed(raw)
    }

    func handle(_ result: Result<ASAuthorization, any Error>) async {
        switch result {
        case let .failure(error):
            rawNonce = nil
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            message = "Không đăng nhập được với Apple. Bản dựng này có thể chưa bật Đăng nhập với Apple."
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                rawNonce = nil
                message = "Apple không trả về thông tin đăng nhập hợp lệ. Thử lại."
                return
            }
            await finishSignIn(identityToken: token)
        }
    }

    func finishSignIn(identityToken: String) async {
        guard let nonce = rawNonce else { message = "Lần đăng nhập đã hết hạn. Thử lại."; return }
        rawNonce = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let device = try? await identity.current()
            let user = try await manager.signIn(identityToken: identityToken, rawNonce: nonce, deviceId: device)
            await enter(userId: user.id, name: user.displayName)
        } catch SyncTransportError.unauthorized {
            message = "Máy chủ không xác nhận lần đăng nhập này. Thử lại."
        } catch SyncTransportError.offline {
            message = "Không kết nối được máy chủ. Dữ liệu trên máy vẫn nguyên vẹn."
        } catch {
            message = "Máy chủ chưa sẵn sàng. Thử lại sau."
        }
    }

    /// The user's answer to "attach the data on this device to the account?".
    func chooseAttach(_ attach: Bool) {
        guard case .choosingAttach = state, let user = pendingUser else { return }
        do {
            try scope.bind(userId: user, attachLocalData: attach)
            state = .signedIn(name: pendingName)
            pendingUser = nil
            onSessionChanged?()
        } catch {
            message = "Không lưu được lựa chọn này. Thử lại."
        }
    }

    // MARK: Sign out

    /// Forgets the tokens at once (there is no server-side sign-out yet, docs/08 §6). Wiping local data is the caller's next step.
    func endSession() async {
        await manager.signOut()
        state = .signedOut
        pendingUser = nil
        message = nil
        onSessionChanged?()
    }

    func wipeLocalData(seed: ContentSeed, now: Date = Date()) throws {
        try scope.signOut(deleteLocalData: true, seed: seed, now: now)
    }

    // MARK: Private

    private func enter(userId: UUID, name: String?) async {
        do {
            switch try scope.check(userId: userId) {
            case .attachChoiceNeeded:
                pendingUser = userId
                pendingName = name
                state = .choosingAttach
            case .ready:
                state = .signedIn(name: name)
                onSessionChanged?()
            case .otherAccountOnDevice:
                await manager.signOut() // never hold tokens for an account that may not touch this data
                state = .signedOut
                message = "Dữ liệu trên máy thuộc một tài khoản khác. Đăng xuất tài khoản đó và xoá dữ liệu trên máy trước khi đăng nhập tài khoản này."
            }
        } catch {
            await manager.signOut()
            state = .signedOut
            message = "Không đọc được dữ liệu trên máy. Thử lại."
        }
    }

    /// `CaliAPIBaseURL` of Info.plist (a build setting); a dev base URL from Diagnostics wins in DEBUG.
    static func configuredBaseURL() -> URL? {
        #if DEBUG
        if let dev = DevCredentialStore.read(.baseURL), let url = validURL(dev, allowHTTP: true) { return url }
        #endif
        return (Bundle.main.object(forInfoDictionaryKey: "CaliAPIBaseURL") as? String).flatMap { validURL($0, allowHTTP: false) }
    }

    private static func validURL(_ text: String, allowHTTP: Bool) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.host != nil else { return nil }
        return url.scheme == "https" || (allowHTTP && url.scheme == "http") ? url : nil
    }
}

/// No server address configured: every call looks like being offline.
private struct UnavailableAuthAPI: AuthAPI {
    func signInWithApple(identityToken: String, nonce: String, deviceId: UUID?) async throws -> AuthTokens { throw SyncTransportError.offline }
    func refresh(refreshToken: String, deviceId: UUID?) async throws -> AuthTokens { throw SyncTransportError.offline }
}
