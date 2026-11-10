import Foundation

/// `SyncAPI` over HTTPS (docs/08). A 401 triggers one token refresh and one retry of the same request; every
/// other failure is mapped to `SyncTransportError` for the engine. The access token and the response body are
/// never logged.
public struct URLSessionSyncAPI: SyncAPI {
    public var baseURL: URL
    public var session: URLSession
    public var tokens: any SyncTokenProvider

    public init(baseURL: URL, session: URLSession = .shared, tokens: any SyncTokenProvider) {
        self.baseURL = baseURL
        self.session = session
        self.tokens = tokens
    }

    public func push(_ request: SyncPushRequest) async throws -> SyncPushResponse {
        let body = try SyncWireCoding.encoder().encode(request)
        let (data, response) = try await send(method: "POST", path: "v1/sync/push", query: [], body: body)
        switch response.statusCode {
        case 200:
            return try SyncWireCoding.decoder().decode(SyncPushResponse.self, from: data)
        case 401:
            throw SyncTransportError.unauthorized
        case 409:
            if Self.problemCode(data) == "device_owner_mismatch" { throw SyncTransportError.deviceOwnerMismatch }
            throw SyncTransportError.server(status: 409)
        case 429:
            throw SyncTransportError.rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        case 400, 413:
            throw SyncTransportError.batchRefused(status: response.statusCode, code: Self.problemCode(data))
        default:
            throw SyncTransportError.server(status: response.statusCode)
        }
    }

    public func pull(cursor: String?, limit: Int) async throws -> SyncPullResponse {
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let (data, response) = try await send(method: "GET", path: "v1/sync/pull", query: query, body: nil)
        switch response.statusCode {
        case 200: return try SyncWireCoding.decoder().decode(SyncPullResponse.self, from: data)
        case 401: throw SyncTransportError.unauthorized
        case 410: throw SyncTransportError.cursorExpired
        case 429: throw SyncTransportError.rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        case 400: throw SyncTransportError.batchRefused(status: 400, code: Self.problemCode(data))
        default: throw SyncTransportError.server(status: response.statusCode)
        }
    }

    private func send(method: String, path: String, query: [URLQueryItem], body: Data?) async throws -> (Data, HTTPURLResponse) {
        var token: String
        do { token = try await tokens.accessToken() } catch let error as SyncTransportError { throw error } catch { throw SyncTransportError.unauthorized }
        var attempt = 0
        while true {
            var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { components.queryItems = query }
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.httpBody = body
            request.timeoutInterval = 30
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
            if http.statusCode == 401, attempt == 0 {
                attempt += 1
                do {
                    try await tokens.refreshAccessToken()
                    token = try await tokens.accessToken()
                } catch let error as SyncTransportError {
                    throw error // offline stays offline: it is not a reason to sign in again
                } catch {
                    throw SyncTransportError.unauthorized
                }
                continue
            }
            return (data, http)
        }
    }

    /// `code` of an `application/problem+json` body, if it is one.
    static func problemCode(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
    }
}
