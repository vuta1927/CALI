import CaliDomain
import CryptoKit
import Foundation

/// `UserProfile` of contracts/openapi.yaml.
public struct UserProfile: Codable, Equatable, Sendable {
    public var id: UUID
    public var displayName: String?
    public var timezone: String
    public var createdAt: Date

    public init(id: UUID, displayName: String?, timezone: String, createdAt: Date) {
        self.id = id
        self.displayName = displayName
        self.timezone = timezone
        self.createdAt = createdAt
    }
}

/// `AuthTokens`. Never printed: the description is redacted so a stray `print` or log line cannot leak a credential.
public struct AuthTokens: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String
    public var refreshToken: String
    public var expiresInSeconds: Int
    public var user: UserProfile

    public init(accessToken: String, refreshToken: String, expiresInSeconds: Int, user: UserProfile) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresInSeconds = expiresInSeconds
        self.user = user
    }

    public var description: String { "AuthTokens(‹redacted›)" }
    public var debugDescription: String { description }
}

public protocol AuthAPI: Sendable {
    /// `POST /v1/auth/apple`. `nonce` is the RAW string; Apple was given its hash (`AppleNonce.hashed`).
    func signInWithApple(identityToken: String, nonce: String, deviceId: UUID?) async throws -> AuthTokens
    /// `POST /v1/auth/refresh`. The presented token is spent by the server, success or not.
    func refresh(refreshToken: String, deviceId: UUID?) async throws -> AuthTokens
}

/// The nonce pair of Sign in with Apple (ADR-071): the app gives Apple the lowercase hex SHA-256 of a random string and
/// gives the API the string itself.
public enum AppleNonce {
    /// 32 random bytes as base64url (43 characters, inside the contract's 8...256).
    public static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no secure random bytes")
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func hashed(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// HTTP for the two anonymous auth endpoints. The refresh token and the identity token are request bodies only: never
/// logged, never put in a URL.
public struct URLSessionAuthAPI: AuthAPI {
    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private struct AppleBody: Encodable { var identityToken: String; var nonce: String; var deviceId: UUID? }
    private struct RefreshBody: Encodable { var refreshToken: String; var deviceId: UUID? }

    public func signInWithApple(identityToken: String, nonce: String, deviceId: UUID?) async throws -> AuthTokens {
        try await post("v1/auth/apple", AppleBody(identityToken: identityToken, nonce: nonce, deviceId: deviceId))
    }

    public func refresh(refreshToken: String, deviceId: UUID?) async throws -> AuthTokens {
        try await post("v1/auth/refresh", RefreshBody(refreshToken: refreshToken, deviceId: deviceId))
    }

    private func post<B: Encodable>(_ path: String, _ body: B) async throws -> AuthTokens {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try SyncWireCoding.encoder().encode(body)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, http: HTTPURLResponse
        do {
            let (d, r) = try await session.data(for: request)
            guard let h = r as? HTTPURLResponse else { throw SyncTransportError.offline }
            (data, http) = (d, h)
        } catch let error as SyncTransportError {
            throw error
        } catch {
            throw SyncTransportError.offline
        }
        switch http.statusCode {
        case 200:
            guard let tokens = try? SyncWireCoding.decoder().decode(AuthTokens.self, from: data) else { throw SyncTransportError.server(status: 200) }
            return tokens
        case 401: throw SyncTransportError.unauthorized // every refusal is the same 401, no reason
        case 429: throw SyncTransportError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        case 400, 413, 415: throw SyncTransportError.batchRefused(status: http.statusCode, code: nil)
        default: throw SyncTransportError.server(status: http.statusCode) // 503: Apple's keys could not be fetched, try later
        }
    }
}
