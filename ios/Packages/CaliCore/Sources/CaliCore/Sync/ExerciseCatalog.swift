import CaliDomain
import Foundation

/// `GET /v1/exercises` (BE-001): the published exercise catalog. Anonymous, paged by an opaque cursor.
public protocol ExerciseCatalogAPI: Sendable {
    func page(cursor: String?, limit: Int) async throws -> ExerciseCatalogPage
}

public struct ExerciseCatalogPage: Sendable, Equatable {
    public var items: [Exercise]
    /// The media the server lists for each exercise (BE-006): metadata and a short-lived signed URL, no file.
    public var media: [UUID: [ServerMedia]]
    public var nextCursor: String?
    public var hasMore: Bool

    public init(items: [Exercise], media: [UUID: [ServerMedia]] = [:], nextCursor: String?, hasMore: Bool) {
        self.items = items
        self.media = media
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

/// One `ExerciseMedia` of the API.
public struct ServerMedia: Decodable, Sendable, Equatable {
    public var id: UUID
    public var kind: String
    public var contentVersion: Int
    public var url: URL?
    public var urlExpiresAt: String?
    public var mimeType: String
    public var sha256: String
    public var sizeBytes: Int?

    public init(id: UUID, kind: String, contentVersion: Int = 1, url: URL?, urlExpiresAt: String? = nil, mimeType: String, sha256: String, sizeBytes: Int? = nil) {
        self.id = id
        self.kind = kind
        self.contentVersion = contentVersion
        self.url = url
        self.urlExpiresAt = urlExpiresAt
        self.mimeType = mimeType
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
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
            let exercises = wire.items.compactMap(\.value)
            return ExerciseCatalogPage(items: exercises.map(ExerciseCatalog.local),
                                       media: Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0.media ?? []) }),
                                       nextCursor: wire.nextCursor, hasMore: wire.hasMore)
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
    var media: [ServerMedia]?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(ExerciseType.self, forKey: .type)
        discipline = try c.decodeIfPresent(String.self, forKey: .discipline)
        focusTags = try c.decodeIfPresent([String].self, forKey: .focusTags)
        equipment = try c.decode([String].self, forKey: .equipment)
        cues = try c.decode([String].self, forKey: .cues)
        catalogVersion = try c.decode(Int.self, forKey: .catalogVersion)
        // A media item this build cannot read is skipped; the exercise itself still loads.
        media = (try? c.decodeIfPresent([LossyMedia].self, forKey: .media))?.compactMap(\.value)
    }

    private enum Keys: String, CodingKey { case id, slug, name, type, discipline, focusTags, equipment, cues, catalogVersion, media }

    private struct LossyMedia: Decodable {
        var value: ServerMedia?
        init(from decoder: any Decoder) throws { value = try? ServerMedia(from: decoder) }
    }
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
        // The user's own photo wins; a server poster only replaces another server poster or none.
        if let poster = server.poster, merged.poster == nil || ExerciseMediaCache.isServerCached(merged.poster) { merged.poster = poster }
        return merged
    }
}

/// Brings the local catalog in line with the server's published exercises. Offline or failing, it changes nothing.
public struct ExerciseCatalogRefresher: Sendable {
    private let api: any ExerciseCatalogAPI
    private let store: ContentStore
    private let media: ExerciseMediaCache?

    /// `media`: where server posters are kept; without it the catalog is read without images.
    public init(api: any ExerciseCatalogAPI, store: ContentStore, media: ExerciseMediaCache? = nil) {
        self.api = api
        self.store = store
        self.media = media
    }

    public init(api: any ExerciseCatalogAPI, coordinator: WorkoutCoordinator, media: ExerciseMediaCache? = nil) {
        self.init(api: api, store: ContentStore(writer: coordinator.writer), media: media)
    }

    /// Returns how many exercises were added or changed.
    @discardableResult
    public func refresh(now: Date = Date()) async throws -> Int {
        var fetched: [Exercise] = []
        var listed: [UUID: [ServerMedia]] = [:]
        var cursor: String?
        for _ in 0..<50 { // 5 000 exercises is far beyond any catalog; the bound only stops a server that never ends a cursor
            let page = try await api.page(cursor: cursor, limit: 100)
            fetched += page.items
            listed.merge(page.media) { $1 }
            guard page.hasMore, let next = page.nextCursor, next != cursor else { break }
            cursor = next
        }
        guard !fetched.isEmpty else { return 0 }
        if let media {
            for index in fetched.indices {
                fetched[index].poster = await media.poster(from: listed[fetched[index].id] ?? [], now: now)
            }
        }
        let local = Dictionary(uniqueKeysWithValues: try store.load().catalog.map { ($0.id, $0) })
        let changed = fetched.map { ExerciseCatalog.merge($0, onto: local[$0.id]) }.filter { $0 != local[$0.id] }
        guard !changed.isEmpty else { return 0 }
        try store.apply(ContentChange(exercises: changed), now: now)
        return changed.count
    }
}
