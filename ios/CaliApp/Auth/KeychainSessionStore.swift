import CaliCore
import Foundation
import Security

/// IOS-008: the session (access token, the newest refresh token, user id) in the Keychain, this device only and after the
/// first unlock so a background sync can read it. Never in UserDefaults, files, logs or backups.
struct KeychainSessionStore: SessionStore {
    private let service: String
    private let account = "session"

    init(service: String = "cali.session") { self.service = service }

    func load() throws -> StoredSession? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        return try JSONDecoder().decode(StoredSession.self, from: data)
    }

    func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func clear() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    enum KeychainError: Error { case status(OSStatus) }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
