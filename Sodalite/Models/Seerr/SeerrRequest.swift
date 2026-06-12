import Foundation

struct SeerrRequest: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let status: SeerrRequestStatus
    let createdAt: String?
    let updatedAt: String?
    let type: SeerrMediaType
    let is4k: Bool?
    let media: SeerrRequestMedia?
    let seasons: [SeerrRequestSeason]?
    let requestedBy: SeerrUser?
}

struct SeerrRequestMedia: Codable, Sendable, Equatable {
    let id: Int?
    let tmdbId: Int?
    let mediaType: SeerrMediaType?
    let status: SeerrMediaStatus?
    /// Sonarr/Radarr server id the media is attached to.
    let serviceId: Int?
}

struct SeerrRequestSeason: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let seasonNumber: Int
    let status: SeerrMediaStatus?
}

struct SeerrCreateRequestBody: Encodable, Sendable {
    let mediaType: SeerrMediaType
    let mediaId: Int
    let seasons: [Int]?
    let serverId: Int?
    let profileId: Int?
    let rootFolder: String?
    let languageProfileId: Int?
    /// Sonarr/Radarr tag ids attached to the resulting download.
    /// Empty array and nil both encode as "no tags", we send nil to
    /// stay forwards-compatible with older Jellyseerr builds that
    /// might not recognise the field.
    let tags: [Int]?

    init(
        mediaType: SeerrMediaType,
        mediaId: Int,
        seasons: [Int]? = nil,
        serverId: Int? = nil,
        profileId: Int? = nil,
        rootFolder: String? = nil,
        languageProfileId: Int? = nil,
        tags: [Int]? = nil
    ) {
        self.mediaType = mediaType
        self.mediaId = mediaId
        self.seasons = seasons
        self.serverId = serverId
        self.profileId = profileId
        self.rootFolder = rootFolder
        self.languageProfileId = languageProfileId
        self.tags = tags
    }
}
