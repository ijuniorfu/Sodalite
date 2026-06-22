import Foundation
import os.log
import Security

/// Mirrors active Jellyfin credentials into the shared keychain access group the TopShelf extension reads. One slot per tvOS user (nil → `tvOSSession_default`, multi-user → `tvOSSession_<id>`), each a JSON `Payload`; re-mirrored on every login/profile-switch/logout. Own service bucket (`…Sodalite.shared`) to keep it separate from the app's primary entries.
enum SharedSessionMirror {
    static let service = "de.superuser404.Sodalite.shared"

    /// JSON shape per slot; keep in sync with the decoder in `SodaliteTopShelf/SharedSession.swift`.
    struct Payload: Codable {
        let serverURL: String
        let userID: String
        let accessToken: String
    }

    static func write(tvUserID: String?, serverURL: URL, userID: String, accessToken: String) {
        let slot = KeychainKeys.sharedSession(tvUserID: tvUserID)
        let payload = Payload(
            serverURL: serverURL.absoluteString,
            userID: userID,
            accessToken: accessToken
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            log.error("SharedSessionMirror.write encode failed slot=\(slot, privacy: .public)")
            return
        }
        save(data, account: slot)
    }

    static func clear(tvUserID: String?) {
        let slot = KeychainKeys.sharedSession(tvUserID: tvUserID)
        delete(account: slot)
    }

    /// Wipes every shared-session slot (full logout). Enumerates by `tvOSSession_` account-prefix since SecItem has no prefix match.
    static func clearAll() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        if let group = resolvedAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix("tvOSSession_")
            else { continue }
            delete(account: account)
        }
    }

    private static func save(_ data: Data, account: String) {
        delete(account: account)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if let group = resolvedAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            log.error("SharedSessionMirror.save failed: status=\(status, privacy: .public) account=\(account, privacy: .public)")
        }
    }

    private static func delete(account: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = resolvedAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        SecItemDelete(query as CFDictionary)
    }

    /// Materializes `<TeamID>.de.superuser404.Sodalite.shared` at runtime ($(AppIdentifierPrefix) expands only at codesign). Cribs the team prefix off any visible keychain item; if none exist (fresh install pre-login) drops the access group and lets the OS pick the first entitled one. Caches only a SUCCESSFUL probe: a `static let` would pin the nil fallback forever after an empty-keychain probe, so writes/deletes could target different groups and strand a stale TopShelf session after logout.
    private static var cachedAccessGroup: String?
    private static var resolvedAccessGroup: String? {
        if let cachedAccessGroup { return cachedAccessGroup }
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(probe as CFDictionary, &item)
        guard status == errSecSuccess,
              let attrs = item as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let dot = group.firstIndex(of: ".")
        else {
            log.notice("SharedSessionMirror could not probe team prefix; falling back to default group")
            return nil
        }
        let prefix = String(group[..<group.index(after: dot)])
        let resolved = prefix + "de.superuser404.Sodalite.shared"
        cachedAccessGroup = resolved
        return resolved
    }

    private static let log = Logger(subsystem: "de.superuser404.Sodalite", category: "TopShelfMirror")
}
