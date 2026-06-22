import Foundation

struct SeerrMedia: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let mediaType: SeerrMediaType
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let mediaInfo: SeerrMediaInfo?

    var displayTitle: String {
        title ?? name ?? originalTitle ?? originalName ?? ""
    }

    var displayYear: String? {
        let raw = releaseDate ?? firstAirDate
        guard let raw, raw.count >= 4 else { return nil }
        return String(raw.prefix(4))
    }

    /// Cross-type stable id for dedup + ForEach: TMDB reuses numeric ids per type, so the mediaType prefix is required.
    var stableKey: String { "\(mediaType.rawValue)-\(id)" }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(mediaType)
    }

    static func == (lhs: SeerrMedia, rhs: SeerrMedia) -> Bool {
        lhs.id == rhs.id && lhs.mediaType == rhs.mediaType
    }

    /// Stub for navigating to CatalogDetailView with only a TMDB id; its load() issues `/movie/{id}` or `/tv/{id}` and fills the rest.
    static func stub(tmdbID: Int, mediaType: SeerrMediaType) -> SeerrMedia {
        SeerrMedia(
            id: tmdbID,
            mediaType: mediaType,
            title: nil, name: nil,
            originalTitle: nil, originalName: nil,
            overview: nil,
            posterPath: nil, backdropPath: nil,
            releaseDate: nil, firstAirDate: nil,
            voteAverage: nil,
            mediaInfo: nil
        )
    }
}

struct SeerrMediaInfo: Codable, Sendable, Equatable {
    let id: Int?
    let tmdbId: Int?
    let status: SeerrMediaStatus?
    let requests: [SeerrRequest]?
    /// Sonarr-scan per-season status, authoritative for "is season N on the server?" independent of `requests` (manual imports show `.available`, deleted files revert to `.unknown`).
    let seasons: [SeerrMediaSeason]?
}

struct SeerrMediaSeason: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let seasonNumber: Int
    let status: SeerrMediaStatus?
    let status4k: SeerrMediaStatus?
}
