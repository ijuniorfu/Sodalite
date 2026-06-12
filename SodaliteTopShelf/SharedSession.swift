import Foundation
import os.log
import Security

private let log = Logger(subsystem: "de.superuser404.Sodalite.TopShelf", category: "SharedSession")

/// Pulls the active Jellyfin session out of the shared keychain
/// access group that the main app mirrors credentials into. Read
/// only — the extension never writes here.
///
/// The main app remains the single source of truth for auth state;
/// every login/switch/logout writes through `SharedSessionMirror`
/// which keeps the per-tvOS-user JSON slot in sync. If the slot is
/// missing or fails to decode we treat the session as absent and the
/// TopShelf renders empty rather than guessing.
struct SharedSession: Sendable {
    let baseURL: URL
    let userID: String
    let accessToken: String

    /// JSON shape the main app writes into each tvOSSession_<id>
    /// slot. Kept in sync with `SharedSessionMirror.Payload`.
    private struct Payload: Codable {
        let serverURL: String
        let userID: String
        let accessToken: String
    }

    /// Reads the per-tvOS-user blob the main app's
    /// `SharedSessionMirror.write` deposits. Nil tvUserID (single-
    /// user Apple TV) reads the `tvOSSession_default` slot, identical
    /// to the no-multi-user shape.
    static func read(tvUserID: String?) -> SharedSession? {
        let slot = sharedSessionSlot(tvUserID: tvUserID)
        guard let data = readSharedKeychainData(account: slot) else {
            log.info("SharedSession.read slot=\(slot, privacy: .public) data=nil group=\(resolvedAccessGroup, privacy: .public)")
            return nil
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let url = URL(string: payload.serverURL)
        else {
            log.error("SharedSession.read decode failed slot=\(slot, privacy: .public)")
            return nil
        }
        log.info("SharedSession.read slot=\(slot, privacy: .public) ok=true group=\(resolvedAccessGroup, privacy: .public)")
        return SharedSession(baseURL: url, userID: payload.userID, accessToken: payload.accessToken)
    }
}

/// Mirrors `KeychainKeys.sharedSession(tvUserID:)` from the main
/// target. Duplicated here so the TopShelf extension stays
/// source-independent from Sodalite's target.
private func sharedSessionSlot(tvUserID: String?) -> String {
    "tvOSSession_\(tvUserID ?? "default")"
}

enum SharedSessionKeys {
    static let service = "de.superuser404.Sodalite.shared"
    static let accessGroup = "$(AppIdentifierPrefix)de.superuser404.Sodalite.shared"
}

private func readSharedKeychainData(account: String) -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: SharedSessionKeys.service,
        kSecAttrAccount as String: account,
        kSecAttrAccessGroup as String: resolvedAccessGroup,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return data
}

/// `$(AppIdentifierPrefix)` only expands inside entitlement plists —
/// at runtime the prefix is the team ID followed by a dot, recovered
/// here by querying any one keychain item the process can already
/// see and reading its `kSecAttrAccessGroup` back. Falls back to the
/// raw entitlement value as a last resort so a brand-new install
/// (with nothing in the keychain yet) still finds its bucket on the
/// next read.
private let resolvedAccessGroup: String = {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnAttributes as String: true,
    ]
    var item: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess,
       let attrs = item as? [String: Any],
       let group = attrs[kSecAttrAccessGroup as String] as? String,
       let dot = group.firstIndex(of: ".") {
        let prefix = String(group[..<group.index(after: dot)])
        return prefix + "de.superuser404.Sodalite.shared"
    }
    return SharedSessionKeys.accessGroup
}()
