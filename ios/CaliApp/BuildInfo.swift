import Foundation

/// Version and build identity read from the app's Info.plist.
/// `CaliBuildSHA` is filled from the `CALI_BUILD_SHA` build setting (CI passes the commit SHA).
struct BuildInfo: Equatable, Sendable {
    static let shaKey = "CaliBuildSHA"
    static let unknown = "unknown"

    let version: String
    let build: String
    let sha: String

    init(infoDictionary: [String: Any]?) {
        let info = infoDictionary ?? [:]
        version = Self.string(info, "CFBundleShortVersionString")
        build = Self.string(info, "CFBundleVersion")
        sha = Self.string(info, Self.shaKey)
    }

    static var current: BuildInfo {
        BuildInfo(infoDictionary: Bundle.main.infoDictionary)
    }

    private static func string(_ info: [String: Any], _ key: String) -> String {
        guard let value = info[key] as? String, !value.isEmpty else { return unknown }
        return value
    }
}
