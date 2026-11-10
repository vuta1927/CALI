import CaliDomain
import Foundation

/// `GET /v1/exercises` (BE-001): the published exercise catalog. Anonymous, paged by an opaque cursor.
public protocol ExerciseCatalogAPI: Sendable {
    func page(cursor: String?, limit: Int) async throws -> ExerciseCatalogPage
}

public struct ExerciseCatalogPage: Sendable, Equatable {
    public var items: [Exercise]
    public var nextCursor: String?
    public var hasMore: Bool

    public init(items: [Exercise], nextCursor: String?, hasMore: Bool) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct URLSessionExerciseCatalogAPI: ExerciseCatalogAPI {
    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func page(cursor: String?, limit: Int) async throws -> ExerciseCatalogPage {
        var parts = URLComponents(url: baseURL.appendingPathComponent("v1/exercises"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 30
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
            guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { throw SyncTransportError.server(status: 200) }
            return ExerciseCatalogPage(items: wire.items.compactMap(\.value).map(ExerciseCatalog.local), nextCursor: wire.nextCursor, hasMore: wire.hasMore)
        case 429: throw SyncTransportError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default: throw SyncTransportError.server(status: http.statusCode)
        }
    }

    /// One exercise the app cannot read (a type it does not know yet) is skipped, not a failed page.
    private struct Lossy: Decodable {
        var value: ServerExercise?
        init(from decoder: any Decoder) throws { value = try? ServerExercise(from: decoder) }
    }

    private struct Wire: Decodable {
        var items: [Lossy]
        var nextCursor: String?
        var hasMore: Bool
    }
}

/// An `Exercise` of the API (OpenAPI `Exercise`). Media is not read here: posters and videos are IOS-006.
struct ServerExercise: Decodable, Equatable {
    var id: UUID
    var slug: String
    var name: String
    var type: ExerciseType
    var discipline: String?
    var focusTags: [String]?
    var equipment: [String]
    var cues: [String]
    var catalogVersion: Int
}

public enum ExerciseCatalog {
    /// What the server does not know (level, muscle names, common mistakes, the placeholder poster) gets a neutral value; an
    /// exercise already on the phone keeps its own values for those fields (`merge`).
    static func local(_ s: ServerExercise) -> Exercise {
        let symbol: String
        switch s.type {
        case .staticHold: symbol = "figure.core.training"
        case .reps, .timedReps: symbol = "figure.strengthtraining.functional"
        case .distance, .duration: symbol = "figure.run"
        case .load: symbol = "dumbbell.fill"
        default: symbol = "figure.mixed.cardio"
        }
        let palette = s.slug.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 7 }
        return Exercise(id: s.id, slug: s.slug, name: s.name, type: s.type, level: .beginner, equipment: s.equipment,
                        muscles: s.focusTags ?? [], cues: s.cues, mistakes: [], catalogVersion: s.catalogVersion, symbol: symbol, paletteIndex: palette)
    }

    /// Server fields over the local row; the local-only fields stay.
    static func merge(_ server: Exercise, onto local: Exercise?) -> Exercise {
        guard var merged = local else { return server }
        merged.slug = server.slug
        merged.name = server.name
        merged.type = server.type
        merged.equipment = server.equipment
        merged.cues = server.cues
        merged.catalogVersion = server.catalogVersion
        return merged
    }
}

/// Brings the local catalog in line with the server's published exercises. Offline or failing, it changes nothing.
public struct ExerciseCatalogRefresher: Sendable {
    private let api: any ExerciseCatalogAPI
    private let store: ContentStore

    public init(api: any ExerciseCatalogAPI, store: ContentStore) {
        self.api = api
        self.store = store
    }

    public init(api: any ExerciseCatalogAPI, coordinator: WorkoutCoordinator) {
        self.init(api: api, store: ContentStore(writer: coordinator.writer))
    }

    /// Returns how many exercises were added or changed.
    @discardableResult
    public func refresh(now: Date = Date()) async throws -> Int {
        var fetched: [Exercise] = []
        var cursor: String?
        for _ in 0..<50 { // 5 000 exercises is far beyond any catalog; the bound only stops a server that never ends a cursor
            let page = try await api.page(cursor: cursor, limit: 100)
            fetched += page.items
            guard page.hasMore, let next = page.nextCursor, next != cursor else { break }
            cursor = next
        }
        guard !fetched.isEmpty else { return 0 }
        let local = Dictionary(uniqueKeysWithValues: try store.load().catalog.map { ($0.id, $0) })
        let changed = fetched.map { ExerciseCatalog.merge($0, onto: local[$0.id]) }.filter { $0 != local[$0.id] }
        guard !changed.isEmpty else { return 0 }
        try store.apply(ContentChange(exercises: changed), now: now)
        return changed.count
    }
}
