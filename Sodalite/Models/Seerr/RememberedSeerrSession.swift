import Foundation

/// Seerr session scoped to a Jellyfin profile so switching carries Seerr state across; one per (jellyfinServerID, jellyfinUserID). Cookie is a Jellyseerr `connect.sid`; a 401 on restore is the signal to drop the entry and re-authenticate.
struct RememberedSeerrSession: Codable, Sendable, Equatable {
    let jellyfinUserID: String
    let jellyfinServerID: String
    let seerrServer: SeerrServer
    let cookie: String
}
