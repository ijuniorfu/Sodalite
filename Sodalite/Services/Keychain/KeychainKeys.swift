import Foundation

enum KeychainKeys {
    static let service = "de.superuser404.Sodalite"

    static func accessToken(serverID: String) -> String {
        "accessToken_\(serverID)"
    }

    static func userID(serverID: String) -> String {
        "userID_\(serverID)"
    }

    static func jellyfinPassword(serverID: String) -> String {
        "jellyfinPassword_\(serverID)"
    }

    /// JSON `[RememberedUser]` for one server, single blob so profile add/remove is an atomic write.
    static func rememberedUsers(serverID: String) -> String {
        "rememberedUsers_\(serverID)"
    }

    static let seerrServer = "seerrServer"

    /// JSON `[JellyfinServer]`. Order is significant: front = most-recently added/upserted; picker and settings render in this order.
    static let knownServers = "knownServers"

    /// `JellyfinServer.id` of the active server. Must resolve into a `knownServers` entry when present; cleared only when the last server is removed.
    static let activeServerID = "activeServerID"

    /// Active user's display name, written beside every session save so restore can render the profile header before /Users/Me lands. Centralized key: scattered literals once let a typo split the active-user identity.
    static let activeUserName = "activeUserName"
    /// Active user's avatar PrimaryImageTag, same lifecycle as `activeUserName`.
    static let activeUserImageTag = "activeUserImageTag"

    /// JSON `GuardianPINCrypto.Blob`. Device-global (one household PIN, not per-server); absent = no PIN. Keychain so wiping UserDefaults can't reset the lock or its throttle.
    static let guardianPINBlob = "guardianPINBlob"

    /// JSON `GuardianPINThrottle` (failed-attempt count + lockout deadline). Device-global, keychain to resist tampering.
    static let guardianPINThrottle = "guardianPINThrottle"

    static func seerrSession(serverID: String) -> String {
        "seerrSession_\(serverID)"
    }

    /// JSON `RememberedSeerrSession` per Jellyfin profile, so a profile switch restores each user's own Seerr login instead of re-auth.
    static func rememberedSeerr(jellyfinServerID: String, jellyfinUserID: String) -> String {
        "rememberedSeerr_\(jellyfinServerID)_\(jellyfinUserID)"
    }

    /// Shared-session blob slot keyed by tvOS user; nil (single-user) → `default` slot, multi-user → per-id slot the TopShelf extension reads via TVUserManager.
    static func sharedSession(tvUserID: String?) -> String {
        "tvOSSession_\(tvUserID ?? "default")"
    }
}
