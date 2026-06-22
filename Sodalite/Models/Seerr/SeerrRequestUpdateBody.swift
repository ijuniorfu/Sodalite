import Foundation

/// PUT body for `/api/v1/request/{id}`; all fields optional, Jellyseerr ignores nil so the Edit sheet sends only diffed fields. `seasons` is the absolute new set (not a delta), nil for movies. `userId` is unused in UI (kept for a future transfer-request feature).
struct SeerrRequestUpdateBody: Encodable, Sendable {
    let serverId: Int?
    let profileId: Int?
    let rootFolder: String?
    let languageProfileId: Int?
    let seasons: [Int]?
    let userId: Int?

    init(
        serverId: Int? = nil,
        profileId: Int? = nil,
        rootFolder: String? = nil,
        languageProfileId: Int? = nil,
        seasons: [Int]? = nil,
        userId: Int? = nil
    ) {
        self.serverId = serverId
        self.profileId = profileId
        self.rootFolder = rootFolder
        self.languageProfileId = languageProfileId
        self.seasons = seasons
        self.userId = userId
    }
}
