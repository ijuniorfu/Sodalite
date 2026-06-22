import Foundation

/// One result row from Jellyfin's subtitle RemoteSearch
/// (`GET /Items/{id}/RemoteSearch/Subtitles/{lang}`). Requires a
/// server-side subtitle provider plugin (OpenSubtitles).
struct RemoteSubtitleInfo: Codable, Sendable, Identifiable, Equatable {
    /// Provider-scoped id, URL-encoded when passed to download; not a plain int, can contain slashes.
    let id: String
    let providerName: String?
    let name: String?
    let format: String?
    let threeLetterISOLanguageName: String?
    let downloadCount: Int?
    let isHashMatch: Bool?
    let comment: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case providerName = "ProviderName"
        case name = "Name"
        case format = "Format"
        case threeLetterISOLanguageName = "ThreeLetterISOLanguageName"
        case downloadCount = "DownloadCount"
        case isHashMatch = "IsHashMatch"
        case comment = "Comment"
    }
}
