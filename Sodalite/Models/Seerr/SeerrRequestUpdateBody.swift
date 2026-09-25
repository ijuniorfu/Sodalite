import Foundation

/// PUT body for `/api/v1/request/{id}`. Seerr requires `mediaType` (OpenAPI-validated, 400 without it) and
/// ASSIGNS every routing field from the body, an omitted one included, so the body is always the request's
/// complete state, never a diff. `seasons` is the absolute new set and mandatory for TV (500 without it).
/// `userId` is unused in UI (kept for a future transfer-request feature).
struct SeerrRequestUpdateBody: Encodable, Sendable, Equatable {
    let mediaType: SeerrMediaType
    let serverId: Int?
    let profileId: Int?
    let rootFolder: String?
    let languageProfileId: Int?
    let tags: [Int]?
    let seasons: [Int]?
    let userId: Int?

    init(
        mediaType: SeerrMediaType,
        serverId: Int? = nil,
        profileId: Int? = nil,
        rootFolder: String? = nil,
        languageProfileId: Int? = nil,
        tags: [Int]? = nil,
        seasons: [Int]? = nil,
        userId: Int? = nil
    ) {
        self.mediaType = mediaType
        self.serverId = serverId
        self.profileId = profileId
        self.rootFolder = rootFolder
        self.languageProfileId = languageProfileId
        self.tags = tags
        self.seasons = seasons
        self.userId = userId
    }
}
