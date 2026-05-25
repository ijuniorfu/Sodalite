import Foundation

/// Status filter for the admin `GET /api/v1/request` endpoint. The
/// raw values are the literal query-string values Jellyseerr accepts
/// (verified against `server/routes/request.ts` mapStatusToTypes).
/// `.all` is the no-filter case Jellyseerr documents as the default.
enum SeerrRequestFilter: String, Codable, Sendable, CaseIterable, Identifiable {
    case pending  = "pending"
    case approved = "approved"
    case declined = "declined"
    case all      = "all"

    var id: String { rawValue }
}
