import Foundation

/// PUT body for `/api/v1/request/{id}`. Every field is optional;
/// Jellyseerr accepts partial bodies and ignores nil fields. The
/// Edit sheet computes a diff against the original `SeerrRequest`
/// before constructing this, so only changed fields are sent.
///
/// `seasons` is the absolute new set (not a delta), matching the
/// request-create body shape. For movies it stays nil.
///
/// `userId` reassignment isn't surfaced in UI today but the field is
/// included so a future "transfer request" feature can reuse the
/// same body without re-modelling.
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
