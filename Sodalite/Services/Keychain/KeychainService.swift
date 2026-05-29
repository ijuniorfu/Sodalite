import Foundation
import Security

protocol KeychainServiceProtocol: Sendable {
    func save(_ data: Data, for key: String) throws
    func save(_ string: String, for key: String) throws
    func loadData(for key: String) throws -> Data?
    func loadString(for key: String) throws -> String?
    func delete(for key: String) throws
    func deleteAll() throws
}

final class KeychainService: KeychainServiceProtocol {
    private let service: String

    init(service: String = KeychainKeys.service) {
        self.service = service
    }

    /// Explicit per-user isolation switch.
    ///
    /// Under `com.apple.developer.user-management = runs-as-current-user`,
    /// the keychain is per-user-isolated by default for items written
    /// in that regime. The defining knob is `kSecUseUserIndependentKeychain`:
    /// `false` (the platform default under multi-user) targets the running
    /// tvOS user's isolated bucket; `true` would target a shared
    /// system-wide bucket.
    ///
    /// We set it explicitly on every SecItem call to (a) document the
    /// contract at the call site, (b) defend against any future Apple
    /// default change, and (c) make the per-user intent reviewable in
    /// diff. See WWDC22 session 110384 and the `kSecUseUserIndependentKeychain`
    /// constant in Apple's Security framework docs.
    ///
    /// Access groups (`kSecAttrAccessGroup`) are an orthogonal concept,
    /// they govern cross-PROCESS sharing (e.g. the TopShelf extension
    /// reading the main app's session blob), not cross-USER sharing. We
    /// therefore do not set an access group here and let the OS pick
    /// the first entitled group for cross-process visibility while
    /// `kSecUseUserIndependentKeychain = false` enforces user isolation.

    func save(_ data: Data, for key: String) throws {
        try delete(for: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseUserIndependentKeychain as String: kCFBooleanFalse as Any,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func save(_ string: String, for key: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try save(data, for: key)
    }

    func loadData(for key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseUserIndependentKeychain as String: kCFBooleanFalse as Any,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.loadFailed(status)
        }
    }

    func loadString(for key: String) throws -> String? {
        guard let data = try loadData(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseUserIndependentKeychain as String: kCFBooleanFalse as Any,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseUserIndependentKeychain as String: kCFBooleanFalse as Any,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            "Keychain save failed: \(status)"
        case .loadFailed(let status):
            "Keychain load failed: \(status)"
        case .deleteFailed(let status):
            "Keychain delete failed: \(status)"
        case .encodingFailed:
            "Failed to encode data for Keychain"
        }
    }
}
