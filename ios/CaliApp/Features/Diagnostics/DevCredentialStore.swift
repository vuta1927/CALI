#if DEBUG
import Foundation
import Security

/// IOS-012: the dev API base URL and JWT, for pointing a dev build at a backend (docs/16). The token lives
/// in the Keychain (this device only, after first unlock), never in UserDefaults, logs or exports; the base URL
/// is not a secret but is kept out of the repo, so it is stored here too. Compiled into DEBUG builds only.
enum DevCredentialStore {
    static let appService = "cali.dev"
    /// Only a test changes this, to keep its own items apart from the ones the running app uses.
    nonisolated(unsafe) static var service = appService

    enum Item: String { case baseURL = "api-base-url", token = "api-jwt" }

    static func read(_ item: Item) -> String? {
        var query = base(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ item: Item, _ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clear(item) }
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(base(item) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = base(item)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func clear(_ item: Item) -> Bool {
        let status = SecItemDelete(base(item) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Launch arguments `-caliDevBaseURL <url>` and `-caliDevToken <jwt>` (from `devicectl ... process launch`) go into the
    /// Keychain, so a dev build can be pointed at a backend without typing on the phone. They exist only on that command line:
    /// nothing is stored in the repo, the binary or UserDefaults (an argument is not persisted).
    static func adoptLaunchArguments(_ defaults: UserDefaults = .standard) {
        if let url = defaults.string(forKey: "caliDevBaseURL") { write(.baseURL, url) }
        if let token = defaults.string(forKey: "caliDevToken") { write(.token, token) }
    }

    private static func base(_ item: Item) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: item.rawValue]
    }
}
#endif
