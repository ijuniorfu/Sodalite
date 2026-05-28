import Foundation

enum KeychainKeys {
    static let service = "de.superuser404.Sodalite"

    static func accessToken(serverID: String) -> String {
        "accessToken_\(serverID)"
    }

    static func serverURL(serverID: String) -> String {
        "serverURL_\(serverID)"
    }

    static func userID(serverID: String) -> String {
        "userID_\(serverID)"
    }

    static func jellyfinPassword(serverID: String) -> String {
        "jellyfinPassword_\(serverID)"
    }

    /// JSON-encoded `[RememberedUser]` array for one server. All
    /// profile-switching state lives under this single blob so
    /// adds/removes are atomic writes.
    static func rememberedUsers(serverID: String) -> String {
        "rememberedUsers_\(serverID)"
    }

    static let seerrServer = "seerrServer"

    /// JSON-encoded `[JellyfinServer]` list. Order is significant:
    /// the front of the list is the most recently added or upserted
    /// server. The picker and settings list render in this order.
    static let knownServers = "knownServers"

    /// The `JellyfinServer.id` of the currently active server. Must
    /// always resolve into an entry of `knownServers` when present.
    /// Cleared only when the user removes the last known server.
    static let activeServerID = "activeServerID"

    static func seerrSession(serverID: String) -> String {
        "seerrSession_\(serverID)"
    }

    /// JSON-encoded `RememberedSeerrSession` for a specific Jellyfin
    /// profile. Lets profile switching restore each user's own Seerr
    /// login instead of forcing them to re-auth on every swap.
    static func rememberedSeerr(jellyfinServerID: String, jellyfinUserID: String) -> String {
        "rememberedSeerr_\(jellyfinServerID)_\(jellyfinUserID)"
    }

    /// Shared-session blob slot keyed by tvOS system user. Nil
    /// (single-user Apple TV) lands in the `default` slot so the
    /// no-multi-user path keeps using one blob, same as today.
    /// Multi-user writes land in a per-identifier slot, which the
    /// TopShelf extension reads via TVUserManager.
    static func sharedSession(tvUserID: String?) -> String {
        "tvOSSession_\(tvUserID ?? "default")"
    }
}
