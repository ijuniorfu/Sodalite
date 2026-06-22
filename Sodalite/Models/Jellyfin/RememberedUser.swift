import Foundation

/// A Jellyfin profile with persisted access token for credential-free switching; one per (server, user). Token is long-lived (invalid only on admin revoke), so a 401 on switch is the signal to drop the entry and re-prompt for password.
struct RememberedUser: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let serverID: String
    let name: String
    let imageTag: String?
    let token: String
    let addedAt: Date

    init(
        id: String,
        serverID: String,
        name: String,
        imageTag: String?,
        token: String,
        addedAt: Date = .now
    ) {
        self.id = id
        self.serverID = serverID
        self.name = name
        self.imageTag = imageTag
        self.token = token
        self.addedAt = addedAt
    }
}
