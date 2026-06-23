import SwiftUI

enum SeerrMediaStatus: Int, Codable, Sendable {
    case unknown = 1
    case pending = 2
    case processing = 3
    case partiallyAvailable = 4
    case available = 5
    /// Client-side only: set by the Jellyfin ground-truth reconcile when a Seerr-"available" title/season is absent from the library (deleted in Radarr/Sonarr, Seerr's cached status still stale). High sentinel so it never collides with a real server status; the server's own deleted/blocklisted values (6/7) decode to `.unknown` via the lenient init.
    case deleted = 1000

    // Lenient decode: newer Seerr adds states (deleted/blocklisted); an unknown int would abort the whole /movie|/tv decode, so fall back to `.unknown`.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        self = SeerrMediaStatus(rawValue: raw) ?? .unknown
    }

    var localizationKey: String {
        switch self {
        case .unknown: "catalog.status.unknown"
        case .pending: "catalog.status.pending"
        case .processing: "catalog.status.processing"
        case .partiallyAvailable: "catalog.status.partiallyAvailable"
        case .available: "catalog.status.available"
        case .deleted: "catalog.status.removed"
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .pending: "clock"
        case .processing: "arrow.triangle.2.circlepath"
        case .partiallyAvailable: "circle.lefthalf.filled"
        case .available: "checkmark.circle.fill"
        case .deleted: "trash"
        }
    }

    var color: Color {
        switch self {
        case .unknown: .gray
        case .pending: .orange
        case .processing: .blue
        case .partiallyAvailable: .teal
        case .available: .green
        case .deleted: .gray
        }
    }
}

enum SeerrRequestStatus: Int, Codable, Sendable {
    case pendingApproval = 1
    case approved = 2
    case declined = 3
    case failed = 4
    case completed = 5

    // Lenient (as SeerrMediaStatus): `completed = 5` is returned for requests on already-available items, so without it any owned library item failed to decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        self = SeerrRequestStatus(rawValue: raw) ?? .pendingApproval
    }

    var localizationKey: String {
        switch self {
        case .pendingApproval: "catalog.requestStatus.pending"
        case .approved: "catalog.requestStatus.approved"
        case .declined: "catalog.requestStatus.declined"
        case .failed: "catalog.requestStatus.failed"
        case .completed: "catalog.requestStatus.completed"
        }
    }
}

enum SeerrMediaType: String, Codable, Sendable {
    case movie
    case tv
    // `/search` returns `person` too; decoded so the array parse succeeds, filtered out in the service layer before UI.
    case person
    // Lenient fallback: mediaType is non-optional on SeerrMedia, so an unrecognized string would abort the whole discover/search array decode. Inert, filtered like `person`.
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = SeerrMediaType(rawValue: raw) ?? .unknown
    }
}
