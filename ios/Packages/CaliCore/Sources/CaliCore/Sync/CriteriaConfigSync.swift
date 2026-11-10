import CaliDomain
import Foundation
import GRDB

/// `GET /v1/criteria-config` (CON-008): the published set-entry criteria and the indicator set. Anonymous, read-only,
/// revalidated with `If-None-Match`. The last good body is kept so the app works offline; without one the bundled
/// version 1 is used (docs/18 §5.3).
public protocol CriteriaConfigAPI: Sendable {
    /// `nil` = 304, the cached copy is current.
    func fetch(ifNoneMatch: String?) async throws -> CriteriaConfigResponse?
}

public struct CriteriaConfigResponse: Sendable, Equatable {
    public var body: Data
    public var etag: String?

    public init(body: Data, etag: String?) {
        self.body = body
        self.etag = etag
    }
}

/// What the screens read: the criteria of the set form and the indicators of the goal pickers.
public struct PublishedConfig: Sendable, Equatable {
    public var criteria: CriteriaConfig
    public var indicators: [IndicatorDefinition]

    public static let bundled = PublishedConfig(criteria: .bundled, indicators: IndicatorDefinition.bundled)

    public init(criteria: CriteriaConfig, indicators: [IndicatorDefinition]) {
        self.criteria = criteria
        self.indicators = indicators
    }

    /// A body that cannot be read (or is older than the bundled version) gives `nil`: the caller keeps what it has.
    /// An indicator this build cannot read is skipped, like an unknown criterion type.
    public static func decode(_ data: Data) -> PublishedConfig? {
        let decoder = DomainJSON.makeDecoder()
        guard let criteria = try? decoder.decode(CriteriaConfig.self, from: data), criteria.version >= CriteriaConfig.bundled.version,
              let set = try? decoder.decode(IndicatorSet.self, from: data) else { return nil }
        return PublishedConfig(criteria: criteria, indicators: set.indicators.indicators.compactMap(\.value))
    }

    private struct IndicatorSet: Decodable {
        struct Inner: Decodable { var indicators: [Lossy] }
        struct Lossy: Decodable {
            var value: IndicatorDefinition?
            init(from decoder: any Decoder) throws { value = try? IndicatorDefinition(from: decoder) }
        }
        var indicators: Inner
    }
}

public struct URLSessionCriteriaConfigAPI: CriteriaConfigAPI {
    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func fetch(ifNoneMatch: String?) async throws -> CriteriaConfigResponse? {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/criteria-config"))
        request.timeoutInterval = 30
        // The app keeps the copy and its ETag itself; URLSession's own cache would turn our 304 into a 200 from its entry.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let ifNoneMatch { request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match") }
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
        case 200: return CriteriaConfigResponse(body: data, etag: http.value(forHTTPHeaderField: "ETag"))
        case 304: return nil
        case 429: throw SyncTransportError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default: throw SyncTransportError.server(status: http.statusCode)
        }
    }
}

/// The last good config body and its ETag, in `sync_state` (publisher content, not user data: `AccountScope.signOut`
/// clears it with the rest and the next launch downloads it again).
public struct CriteriaConfigStore: Sendable {
    static let bodyKey = "criteria_config_body", etagKey = "criteria_config_etag"
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }
    public init(coordinator: WorkoutCoordinator) { self.init(writer: coordinator.writer) }

    /// The cached config, or the bundled one.
    public func load() async -> PublishedConfig {
        let body = try? await writer.read { try String.fetchOne($0, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [Self.bodyKey]) }
        return body.flatMap { Data($0.utf8) }.flatMap(PublishedConfig.decode) ?? .bundled
    }

    func etag() async -> String? {
        (try? await writer.read { try String.fetchOne($0, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [Self.etagKey]) }) ?? nil
    }

    func save(body: String, etag: String?) async throws {
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)", arguments: [Self.bodyKey, body])
            if let etag {
                try db.execute(sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)", arguments: [Self.etagKey, etag])
            } else {
                try db.execute(sql: "DELETE FROM sync_state WHERE key = ?", arguments: [Self.etagKey])
            }
        }
    }
}

public struct CriteriaConfigRefresher: Sendable {
    private let api: any CriteriaConfigAPI
    private let store: CriteriaConfigStore

    public init(api: any CriteriaConfigAPI, store: CriteriaConfigStore) {
        self.api = api
        self.store = store
    }

    /// `true` when a new config was stored. A failed fetch, a 304 or a body this build cannot read change nothing; the
    /// ETag is only sent while the cached body still decodes, so an unreadable copy is replaced.
    @discardableResult
    public func refresh() async throws -> Bool {
        let cachedUsable = await store.load() != .bundled
        guard let response = try await api.fetch(ifNoneMatch: cachedUsable ? await store.etag() : nil) else { return false }
        guard PublishedConfig.decode(response.body) != nil, let text = String(data: response.body, encoding: .utf8) else { return false }
        let changed = text != (try? await store.writer.read { try String.fetchOne($0, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [CriteriaConfigStore.bodyKey]) })
        try await store.save(body: text, etag: response.etag)
        return changed
    }
}
