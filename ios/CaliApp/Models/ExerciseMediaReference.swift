import Foundation
import UniformTypeIdentifiers
import CoreTransferable

struct ImportedPhoto: Transferable, Sendable {
    let reference: ExerciseMediaReference
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            ImportedPhoto(reference: try LocalMedia.importFile(file.file, isVideo: false))
        }
    }
}

struct ImportedVideo: Transferable, Sendable {
    let reference: ExerciseMediaReference
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { file in
            ImportedVideo(reference: try LocalMedia.importFile(file.file, isVideo: true))
        }
    }
}

/// POC local metadata. Relative filenames survive changes to the app container path.
struct ExerciseMediaReference: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case remote, local }
    var source: Source
    var value: String

    static func remote(_ text: String) -> Self? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return Self(source: .remote, value: value)
    }

    var url: URL? {
        switch source {
        case .remote: return Self.remote(value).flatMap { URL(string: $0.value) }
        case .local:
            guard !value.isEmpty, value != ".", value != "..",
                  !value.contains("/"), !value.contains("\\") else { return nil }
            return LocalMedia.directory.appendingPathComponent(value)
        }
    }
}

enum LocalMedia {
    static var directory: URL {
        LocalStore.fileURL.deletingLastPathComponent().appendingPathComponent("exercise-media", isDirectory: true)
    }

    /// Copy instead of persisting a temporary/security-scoped URL. Never upload user files.
    static func importFile(_ source: URL, isVideo: Bool) throws -> ExerciseMediaReference {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        let expected: UTType = isVideo ? .movie : .image
        guard values.isRegularFile == true, let type = values.contentType, type.conforms(to: expected),
              let size = values.fileSize, size > 0, size <= (isVideo ? 200_000_000 : 20_000_000) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + "." + (type.preferredFilenameExtension ?? source.pathExtension)
        let destination = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        return ExerciseMediaReference(source: .local, value: name)
    }

    static func discard(_ reference: ExerciseMediaReference) {
        guard reference.source == .local, let url = reference.url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
