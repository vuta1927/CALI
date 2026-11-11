import CryptoKit
import Foundation
import GRDB

/// `GET /v1/voice-pack` (CON-010, ADR-077): the published spoken cues of one locale. Anonymous, read-only, revalidated
/// with `If-None-Match`. Every cue file is downloaded once, checked against its SHA-256 and kept in `Library/Sounds`, the
/// only folder `UNNotificationSound(named:)` reads (ADR-078).
public protocol VoicePackAPI: Sendable {
    /// `nil` = 304 (the cached pack is current) or 404 (nothing published yet for this locale).
    func fetch(locale: String, ifNoneMatch: String?) async throws -> VoicePackResponse?
}

public struct VoicePackResponse: Sendable, Equatable {
    public var body: Data
    public var etag: String?

    public init(body: Data, etag: String?) {
        self.body = body
        self.etag = etag
    }
}

/// One `VoicePack` of the API. Only what the phone needs is read.
public struct ServerVoicePack: Decodable, Sendable, Equatable {
    public struct Cue: Decodable, Sendable, Equatable {
        public struct Audio: Decodable, Sendable, Equatable {
            public var url: URL?
            public var expiresAt: String?
            public var format: String
            public var sha256: String
            public var byteSize: Int
        }

        public var key: String
        public var text: String
        public var audio: Audio
    }

    public var locale: String
    public var version: Int
    public var cues: [Cue]
}

public struct URLSessionVoicePackAPI: VoicePackAPI {
    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func fetch(locale: String, ifNoneMatch: String?) async throws -> VoicePackResponse? {
        var parts = URLComponents(url: baseURL.appendingPathComponent("v1/voice-pack"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "locale", value: locale)]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 30
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
        case 200: return VoicePackResponse(body: data, etag: http.value(forHTTPHeaderField: "ETag"))
        case 304, 404: return nil
        case 429: throw SyncTransportError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default: throw SyncTransportError.server(status: http.statusCode)
        }
    }
}

/// The cues the phone can play: for each key, the sentence and (when downloaded) the sound file name in `Library/Sounds`.
public struct VoiceCueLibrary: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var text: String
        /// File name in the sounds directory, `nil` when the deployment serves no audio (Development without storage).
        public var soundFile: String?

        public init(text: String, soundFile: String?) {
            self.text = text
            self.soundFile = soundFile
        }
    }

    public var locale: String
    public var version: Int
    public var cues: [String: Entry]

    public static let empty = VoiceCueLibrary(locale: VoicePackStore.locale, version: 0, cues: [:])

    public init(locale: String, version: Int, cues: [String: Entry]) {
        self.locale = locale
        self.version = version
        self.cues = cues
    }

    public subscript(key: VoiceCueKey) -> Entry? { cues[key.rawValue] }
}

/// The library of the last complete pack and its ETag, in `sync_state` (publisher content: sign-out clears it and the
/// next refresh downloads it again; files already in `Library/Sounds` with the right hash are reused).
public struct VoicePackStore: Sendable {
    public static let locale = "vi-VN"
    static let libraryKey = "voice_pack_library", etagKey = "voice_pack_etag"
    /// Prefix of every file this store writes, so cleanup never touches another sound.
    public static let filePrefix = "cali-voice-"
    static let maxBytes = 1_048_576

    public let writer: any DatabaseWriter
    public let soundsDirectory: URL

    public init(writer: any DatabaseWriter, soundsDirectory: URL) {
        self.writer = writer
        self.soundsDirectory = soundsDirectory
    }

    public init(coordinator: WorkoutCoordinator, soundsDirectory: URL) {
        self.init(writer: coordinator.writer, soundsDirectory: soundsDirectory)
    }

    /// `Library/Sounds` of the app container.
    public static var defaultSoundsDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Sounds", isDirectory: true)
    }

    /// `cali-voice-{locale}-v{version}-{key}.caf` (docs/04): a new version never reuses a name iOS may have cached.
    public static func fileName(locale: String, version: Int, key: String) -> String {
        "\(filePrefix)\(locale)-v\(version)-\(key).caf"
    }

    /// The last complete library; empty before the first download. A listed file that has gone missing is dropped, so
    /// the caller falls back to the default sound instead of naming a file iOS cannot find.
    public func load() async -> VoiceCueLibrary {
        guard let text = await value(Self.libraryKey),
              var library = try? JSONDecoder().decode(VoiceCueLibrary.self, from: Data(text.utf8)) else { return .empty }
        for (key, entry) in library.cues {
            if let file = entry.soundFile, !FileManager.default.fileExists(atPath: soundsDirectory.appendingPathComponent(file).path) {
                library.cues[key]?.soundFile = nil
            }
        }
        return library
    }

    func etag() async -> String? { await value(Self.etagKey) }

    func save(_ library: VoiceCueLibrary, etag: String?) async throws {
        let text = String(decoding: try JSONEncoder().encode(library), as: UTF8.self)
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)", arguments: [Self.libraryKey, text])
            if let etag {
                try db.execute(sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)", arguments: [Self.etagKey, etag])
            } else {
                try db.execute(sql: "DELETE FROM sync_state WHERE key = ?", arguments: [Self.etagKey])
            }
        }
    }

    private func value(_ key: String) async -> String? {
        (try? await writer.read { try String.fetchOne($0, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [key]) }) ?? nil
    }
}

public struct VoicePackRefresher: Sendable {
    private let api: any VoicePackAPI
    private let store: VoicePackStore
    private let downloader: any MediaDownloading

    public init(api: any VoicePackAPI, store: VoicePackStore, downloader: any MediaDownloading = URLSessionMediaDownloader()) {
        self.api = api
        self.store = store
        self.downloader = downloader
    }

    /// `true` when a new library was stored. The new pack replaces the old one only when every file it lists is on the
    /// phone and matches its hash; until then the previous pack stays in use (and its files stay), and the ETag is not
    /// saved, so the next refresh tries again and reuses the files already downloaded.
    @discardableResult
    public func refresh(now: Date = Date()) async throws -> Bool {
        let current = await store.load()
        let complete = current.version > 0 && current.cues.values.allSatisfy { $0.soundFile != nil }
        let cachedEtag = complete ? await store.etag() : nil
        guard let response = try await api.fetch(locale: VoicePackStore.locale, ifNoneMatch: cachedEtag),
              let pack = try? JSONDecoder().decode(ServerVoicePack.self, from: response.body),
              pack.locale == VoicePackStore.locale, pack.version >= 1, !pack.cues.isEmpty else { return false }

        var cues: [String: VoiceCueLibrary.Entry] = [:]
        var allFiles = true
        for cue in pack.cues where VoiceCueKey(rawValue: cue.key) != nil || Self.isKey(cue.key) {
            guard cue.audio.url != nil else {
                cues[cue.key] = .init(text: cue.text, soundFile: nil) // no storage on this deployment: default sound
                continue
            }
            let name = VoicePackStore.fileName(locale: pack.locale, version: pack.version, key: cue.key)
            if await ensure(cue.audio, name: name, now: now) {
                cues[cue.key] = .init(text: cue.text, soundFile: name)
            } else {
                allFiles = false
            }
        }
        guard allFiles else { return false }
        let library = VoiceCueLibrary(locale: pack.locale, version: pack.version, cues: cues)
        let storedEtag = await store.etag()
        guard library != current || response.etag != storedEtag else { return false }
        try await store.save(library, etag: response.etag)
        removeFiles(except: Set(cues.values.compactMap(\.soundFile)))
        return library != current
    }

    private func ensure(_ audio: ServerVoicePack.Cue.Audio, name: String, now: Date) async -> Bool {
        let file = store.soundsDirectory.appendingPathComponent(name)
        if let existing = try? Data(contentsOf: file), Self.hash(existing) == audio.sha256 { return true }
        guard audio.format == "caf_ima4", audio.byteSize <= VoicePackStore.maxBytes,
              let url = audio.url, url.scheme?.lowercased() == "https", Self.isLive(audio.expiresAt, now: now),
              let data = try? await downloader.download(url), !data.isEmpty, data.count <= VoicePackStore.maxBytes,
              Self.hash(data) == audio.sha256 else { return false }
        do {
            try FileManager.default.createDirectory(at: store.soundsDirectory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func removeFiles(except keep: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: store.soundsDirectory.path)) ?? []
        for name in names where name.hasPrefix(VoicePackStore.filePrefix) && !keep.contains(name) {
            try? FileManager.default.removeItem(at: store.soundsDirectory.appendingPathComponent(name))
        }
    }

    /// OpenAPI `VoiceCueKey`; a key this build has no use for is still kept (a later build may play it).
    private static func isKey(_ key: String) -> Bool {
        key.range(of: #"^[a-z][a-z0-9_]{0,31}(\.[a-z0-9_]{1,32}){1,3}$"#, options: .regularExpression) != nil
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLive(_ expiresAt: String?, now: Date) -> Bool {
        guard let expiresAt else { return true }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt) else { return false }
        return date > now
    }
}
