import CryptoKit
import Foundation

/// Fetches the bytes behind a signed media URL (BE-006): a plain GET, no credentials, no cookies.
public protocol MediaDownloading: Sendable {
    func download(_ url: URL) async throws -> Data
}

public struct URLSessionMediaDownloader: MediaDownloading {
    public init() {}

    public func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SyncTransportError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0) }
        return data
    }
}

/// Poster images of server exercises, kept on the phone next to the user's own media. A file is named after its SHA-256,
/// so one that exists is the right one and is never downloaded again; the hash is checked before anything is written.
public struct ExerciseMediaCache: Sendable {
    /// Marks a cached server file, so a refresh may replace it and never replaces the user's own photo.
    public static let prefix = "srv-"
    static let maxBytes = 20_000_000
    private static let extensions = ["image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic"]

    public let directory: URL
    private let downloader: any MediaDownloading

    public init(directory: URL, downloader: any MediaDownloading = URLSessionMediaDownloader()) {
        self.directory = directory
        self.downloader = downloader
    }

    public static func isServerCached(_ reference: ExerciseMediaReference?) -> Bool {
        guard let reference else { return false }
        return reference.source == .local && reference.value.hasPrefix(prefix)
    }

    /// The poster (else the thumbnail) of an exercise as a local reference, downloading it when it is not here yet.
    /// `nil` when the server lists none, its URL is missing or expired, or the bytes do not match the listed hash.
    public func poster(from media: [ServerMedia], now: Date = Date()) async -> ExerciseMediaReference? {
        for kind in ["poster", "thumbnail"] {
            for item in media where item.kind == kind {
                if let reference = await ensure(item, now: now) { return reference }
            }
        }
        return nil
    }

    private func ensure(_ item: ServerMedia, now: Date) async -> ExerciseMediaReference? {
        guard let ext = Self.extensions[item.mimeType.lowercased()], Self.isHash(item.sha256) else { return nil }
        let name = "\(Self.prefix)\(item.sha256).\(ext)"
        let file = directory.appendingPathComponent(name)
        let reference = ExerciseMediaReference(source: .local, value: name)
        if FileManager.default.fileExists(atPath: file.path) { return reference }
        guard let url = item.url, url.scheme?.lowercased() == "https", Self.isLive(item.urlExpiresAt, now: now),
              (item.sizeBytes ?? 0) <= Self.maxBytes,
              let data = try? await downloader.download(url), !data.isEmpty, data.count <= Self.maxBytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == item.sha256 else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            return nil
        }
        return reference
    }

    private static func isHash(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isLive(_ expiresAt: String?, now: Date) -> Bool {
        guard let expiresAt else { return true }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: expiresAt) ?? plain.date(from: expiresAt) else { return false }
        return date > now
    }
}
