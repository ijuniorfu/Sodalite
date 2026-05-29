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

    /// Resolves the application-identifier access group at runtime
    /// (`<TeamID>.<bundleID>`). Under tvOS multi-user
    /// (`runs-as-current-user`), this is the per-user-isolated bucket.
    /// Items written into explicitly-named `keychain-access-groups`
    /// (e.g. `de.superuser404.Sodalite`) are cross-user-shared by
    /// design, which is why we must target this bucket explicitly
    /// instead of letting the OS pick the first entitled group.
    ///
    /// The bucket NAME happens to equal `<TeamID>.<bundleID>` (same
    /// as the team-prefixed form of the named group), but the OS
    /// treats the application-identifier resolution path as per-user
    /// and the named-group path as shared.
    ///
    /// Probes once at first access by adding a throwaway item and
    /// reading back the access group the OS picked, which is always
    /// the first entitled group. From there we slice off the team
    /// prefix and stitch on the bundle identifier. Returns nil only
    /// when the probe fails entirely (sandboxed test environment,
    /// missing entitlements), in which case callers fall back to the
    /// previous behavior so writes don't fail outright.
    static let resolvedAppIdentifierGroup: String? = {
        let probeAccount = UUID().uuidString
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "team-prefix-probe",
            kSecAttrAccount as String: probeAccount,
            kSecValueData as String: Data(),
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        let status = SecItemAdd(probe as CFDictionary, &result)
        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let bundleID = Bundle.main.bundleIdentifier
        else { return nil }

        // Clean up the probe item immediately so it doesn't linger.
        let cleanup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "team-prefix-probe",
            kSecAttrAccount as String: probeAccount,
        ]
        SecItemDelete(cleanup as CFDictionary)

        // Extract the team prefix from the resolved group string
        // (`<TeamID>.<something>`) and append the bundle identifier.
        guard let dot = group.firstIndex(of: ".") else { return nil }
        let teamPrefix = String(group[..<dot])
        return "\(teamPrefix).\(bundleID)"
    }()

    private static func applyAccessGroup(_ query: inout [String: Any]) {
        if let group = resolvedAppIdentifierGroup {
            query[kSecAttrAccessGroup as String] = group
        }
    }

    func save(_ data: Data, for key: String) throws {
        try delete(for: key)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        Self.applyAccessGroup(&query)

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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        Self.applyAccessGroup(&query)

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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        Self.applyAccessGroup(&query)

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    func deleteAll() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        Self.applyAccessGroup(&query)

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
