import Foundation

/// A configured Radarr or Sonarr instance inside Seerr. `/service/radarr`
/// and `/service/sonarr` return a list of these; the `isDefault` flag
/// marks the one Seerr uses when the request body omits `serverId`.
struct SeerrServiceServer: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let name: String
    let isDefault: Bool?
    let is4k: Bool?
    let activeProfileId: Int?
    let activeDirectory: String?
    let activeLanguageProfileId: Int?
}

struct SeerrServiceDetails: Codable, Sendable {
    let server: SeerrServiceServer
    let profiles: [SeerrQualityProfile]
    let rootFolders: [SeerrRootFolder]
    let languageProfiles: [SeerrLanguageProfile]?
    /// Sonarr/Radarr tag list. Jellyseerr forwards Radarr/Sonarr's
    /// `/api/v3/tag` response here so the request body can attach
    /// one or more tag ids to the resulting download.
    let tags: [SeerrTag]?
}

struct SeerrTag: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let label: String
}

struct SeerrQualityProfile: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
}

struct SeerrRootFolder: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let path: String
    let freeSpace: Int64?

    var displayPath: String { path }
}

struct SeerrLanguageProfile: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
}
