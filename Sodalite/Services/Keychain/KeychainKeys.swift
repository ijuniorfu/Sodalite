import Foundation

enum KeychainKeys {
    static let service = "de.superuser404.Sodalite"

    static func accessToken(serverID: String) -> String {
        "accessToken_\(serverID)"
    }

    static func userID(serverID: String) -> String {
        "userID_\(serverID)"
    }

    /// A password belongs to one profile, so the key carries the profile. Scoped per server too,
    /// because the same account name can exist on several servers with different passwords.
    static func jellyfinPassword(serverID: String, userID: String) -> String {
        "jellyfinPassword_\(serverID)_\(userID)"
    }

    /// Pre-per-user layout: one password per server, with the owner in a second entry. Both are
    /// migrated into `jellyfinPassword(serverID:userID:)` on launch and then removed.
    static func legacyJellyfinPassword(serverID: String) -> String {
        "jellyfinPassword_\(serverID)"
    }

    /// The user id the legacy per-server password belonged to.
    static func legacyJellyfinPasswordUserID(serverID: String) -> String {
        "jellyfinPasswordUserID_\(serverID)"
    }

    /// JSON `[RememberedUser]` for one server, single blob so profile add/remove is an atomic write.
    static func rememberedUsers(serverID: String) -> String {
        "rememberedUsers_\(serverID)"
    }

    /// JSON `[String]` of profile ids removed here on purpose (Sodalite#45). The remembered list
    /// unions across devices, so a removal has to be published as one, else the device that has not
    /// heard yet hands the profile straight back. Cleared per id by signing in as that profile again.
    static func forgottenUsers(serverID: String) -> String {
        "forgottenUsers_\(serverID)"
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

    /// JSON `[String: LiveDirectStreamMemory.Entry]` keyed by `userID|channelID`: the provider URL each live channel last direct-played from. Keychain, not UserDefaults, because an Xtream-style upstream carries the provider's credentials in its path.
    static let liveDirectStreams = "liveDirectStreams"

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
