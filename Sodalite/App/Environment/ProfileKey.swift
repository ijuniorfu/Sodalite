import Foundation

/// One Jellyfin profile on one server, the scope every per-profile setting is stored and synced
/// under. The string form is `serverID:userID`, the same one `ProfileRef.compositeID` writes, so the
/// project has a single way to write a profile down.
struct ProfileKey: Hashable, Sendable, Codable {
    let serverID: String
    let userID: String

    init(serverID: String, userID: String) {
        self.serverID = serverID
        self.userID = userID
    }

    /// Splits at the first colon. Jellyfin ids are hex, so neither half carries one.
    init?(storageScope: String) {
        guard let colon = storageScope.firstIndex(of: ":") else { return nil }
        let server = String(storageScope[..<colon])
        let user = String(storageScope[storageScope.index(after: colon)...])
        guard !server.isEmpty, !user.isEmpty else { return nil }
        self.init(serverID: server, userID: user)
    }

    var storageScope: String { "\(serverID):\(userID)" }

    /// Short and stable for a log line, the way the iCloud account is written there.
    var fingerprint: String { CloudSyncAccountTransition.fingerprint(storageScope) }
}
