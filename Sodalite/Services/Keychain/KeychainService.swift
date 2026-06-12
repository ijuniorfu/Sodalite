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

    /// Per-user isolation under `com.apple.developer.user-management =
    /// runs-as-current-user` is the OS default for SecItem operations.
    /// `kSecUseUserIndependentKeychain` is the OPT-IN to cross-user
    /// sharing (set it to true on items that should be visible to every
    /// tvOS user). Setting it to false explicitly is rejected as a
    /// param error (-50) on SecItemDelete, so we just omit it: the
    /// implicit default already isolates per user.
    ///
    /// Access groups (`kSecAttrAccessGroup`) are orthogonal, they govern
    /// cross-PROCESS sharing (e.g. the TopShelf extension reading the
    /// main app's session blob), not cross-USER sharing. We omit them
    /// here and let the OS pick the first entitled group.

    func save(_ data: Data, for key: String) throws {
        // Upsert (update-then-add), NOT delete-then-add: the old
        // delete+add destroyed the previous value before the add could
        // fail, so a failed token-refresh save lost the old token, and
        // two interleaved saves could collide on errSecDuplicateItem.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.saveFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
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
