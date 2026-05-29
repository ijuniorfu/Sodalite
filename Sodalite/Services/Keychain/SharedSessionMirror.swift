import Foundation
import os.log
import Security

/// Writes the active Jellyfin credentials into the shared keychain
/// access group that the TopShelf extension reads from. One slot
/// per tvOS system user: nil (single-user Apple TV) folds into
/// `tvOSSession_default`, multi-user lands in `tvOSSession_<id>`.
/// Each slot holds a JSON-encoded `Payload` with server URL,
/// user ID, and access token. Re-mirrored on every login, profile
/// switch, and logout to keep the extension's view in lockstep
/// with the running app.
///
/// Lives in its own service bucket (`…Sodalite.shared`) so the
/// main app's primary keychain entries (in the default access
/// group) stay logically separated from the shelf's narrow
/// projection, even though both physically share the same
/// app-bundle keychain unless the .shared access group resolves at
/// runtime, in which case the mirror lands in that group.
enum SharedSessionMirror {
    static let service = "de.superuser404.Sodalite.shared"

    /// JSON shape stored in each `tvOSSession_<id>` keychain slot.
    /// Kept in sync with the matching decoder in
    /// `SodaliteTopShelf/SharedSession.swift`.
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

    /// Wipes every shared-session blob (default + every per-tvOS-user
    /// slot). Used by clearSession (full logout) so a multi-user setup
    /// doesn't leave one user's mirror behind after a global wipe.
    /// Enumerates the keychain by account-name prefix because SecItem
    /// doesn't accept prefix matching directly.
    static func clearAll() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseUserIndependentKeychain as String: kCFBooleanFalse as Any,
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
            kSecUseUserIndependentKeychain as String: kCFBooleanFalse as Any,
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
            kSecUseUserIndependentKeychain as String: kCFBooleanFalse as Any,
        ]
        if let group = resolvedAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        SecItemDelete(query as CFDictionary)
    }

    /// Materializes the actual `<TeamID>.de.superuser404.Sodalite.shared`
    /// string at runtime, `$(AppIdentifierPrefix)` only expands at
    /// codesign, never at `SecItemAdd`. We crib the team prefix off
    /// any keychain item the process can already see (the main
    /// app's KeychainService has always written at least `activeServer`
    /// by the time the mirror runs). When no items exist yet (truly
    /// fresh install, somehow called pre-login), we drop the access
    /// group from the query and let the OS fall back to the first
    /// entitled group, losing some isolation but keeping the write
    /// from failing outright.
    private static let resolvedAccessGroup: String? = {
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
        return prefix + "de.superuser404.Sodalite.shared"
    }()

    private static let log = Logger(subsystem: "de.superuser404.Sodalite", category: "TopShelfMirror")
}
