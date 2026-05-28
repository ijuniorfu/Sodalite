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
/// which keeps these three keys in sync. If any one of them is
/// missing we treat the session as absent and the TopShelf renders
/// empty rather than guessing.
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

    /// Legacy three-key reader. Used before the per-tvOS-user blob
    /// migration runs. Once `KeychainMigrator` consolidates the old
    /// triplet into `tvOSSession_default`, this path returns nil and
    /// callers should use `read(tvUserID:)` instead.
    static func load() -> SharedSession? {
        let urlString = readSharedKeychainString(account: SharedSessionKeys.serverURL)
        let userID = readSharedKeychainString(account: SharedSessionKeys.userID)
        let token = readSharedKeychainString(account: SharedSessionKeys.accessToken)
        log.info("SharedSession.load url=\(urlString != nil, privacy: .public) user=\(userID != nil, privacy: .public) token=\(token != nil, privacy: .public) group=\(resolvedAccessGroup, privacy: .public)")
        guard let urlString, let url = URL(string: urlString), let userID, let token else {
            return nil
        }
        return SharedSession(baseURL: url, userID: userID, accessToken: token)
    }

    /// Forward-compatible zero-arg accessor. Folds into the
    /// `tvOSSession_default` slot so callers that haven't been
    /// updated to pass a tvUserID still read the single-user blob.
    static func read() -> SharedSession? {
        read(tvUserID: nil)
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

    static let serverURL = "shared.serverURL"
    static let userID = "shared.userID"
    static let accessToken = "shared.accessToken"
}

private func readSharedKeychainString(account: String) -> String? {
    guard let data = readSharedKeychainData(account: account) else { return nil }
    return String(data: data, encoding: .utf8)
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
