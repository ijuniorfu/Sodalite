import Foundation

struct SeerrMovieDetail: Codable, Sendable {
    let id: Int
    let title: String
    let originalTitle: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let runtime: Int?
    let voteAverage: Double?
    let genres: [SeerrGenre]?
    let mediaInfo: SeerrMediaInfo?
    let credits: SeerrCredits?
    let watchProviders: [SeerrWatchProviderRegion]?
    let releases: SeerrReleases?

    var displayYear: String? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }

    func certification(region: String) -> String? {
        seerrCertification(movieReleases: releases, region: region)
    }
}

struct SeerrTVDetail: Codable, Sendable {
    let id: Int
    let name: String
    let originalName: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let genres: [SeerrGenre]?
    let numberOfSeasons: Int?
    let seasons: [SeerrSeason]?
    let mediaInfo: SeerrMediaInfo?
    let credits: SeerrCredits?
    let watchProviders: [SeerrWatchProviderRegion]?
    let contentRatings: SeerrContentRatings?

    var displayYear: String? {
        guard let firstAirDate, firstAirDate.count >= 4 else { return nil }
        return String(firstAirDate.prefix(4))
    }

    func certification(region: String) -> String? {
        seerrCertification(tvRatings: contentRatings, region: region)
    }
}

struct SeerrSeason: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let seasonNumber: Int
    let name: String?
    let overview: String?
    let episodeCount: Int?
    let airDate: String?
    let posterPath: String?
}

struct SeerrGenre: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
}

/// Per-season detail returned from `/tv/{id}/season/{n}`, used to
/// render the read-only episode list inside CatalogDetailView. Note
/// that the request endpoint still only accepts whole seasons; this
/// payload is informational so the user can preview what they're
/// asking for before they hit Submit.
struct SeerrSeasonDetail: Codable, Sendable, Equatable {
    let id: Int
    let seasonNumber: Int
    let name: String?
    let overview: String?
    let airDate: String?
    let episodes: [SeerrEpisode]?
}

struct SeerrEpisode: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let episodeNumber: Int
    let seasonNumber: Int?
    let name: String?
    let overview: String?
    let stillPath: String?
    let airDate: String?
    let voteAverage: Double?
    let runtime: Int?
}

// MARK: - Credits

struct SeerrCastMember: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
    let character: String?
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, character
        case profilePath
    }
}

struct SeerrCredits: Codable, Sendable, Equatable {
    let cast: [SeerrCastMember]?
}

// MARK: - Watch Providers

struct SeerrWatchProvider: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
    let logoPath: String?
}

struct SeerrWatchProviderRegion: Codable, Sendable, Equatable {
    let iso31661: String
    let link: String?
    let flatrate: [SeerrWatchProvider]?
    let buy: [SeerrWatchProvider]?
    let rent: [SeerrWatchProvider]?

    enum CodingKeys: String, CodingKey {
        case iso31661 = "iso_3166_1"
        case link, flatrate, buy, rent
    }
}

// MARK: - Certification

struct SeerrReleases: Codable, Sendable, Equatable {
    struct RegionReleases: Codable, Sendable, Equatable {
        let iso31661: String
        let releaseDates: [ReleaseDate]?

        enum CodingKeys: String, CodingKey {
            case iso31661 = "iso_3166_1"
            case releaseDates = "release_dates"
        }
    }
    struct ReleaseDate: Codable, Sendable, Equatable {
        let certification: String?
    }
    let results: [RegionReleases]?
}

struct SeerrContentRatings: Codable, Sendable, Equatable {
    struct RegionRating: Codable, Sendable, Equatable {
        let iso31661: String
        let rating: String?

        enum CodingKeys: String, CodingKey {
            case iso31661 = "iso_3166_1"
            case rating
        }
    }
    let results: [RegionRating]?
}

func seerrCertification(movieReleases: SeerrReleases?, region: String) -> String? {
    guard let results = movieReleases?.results else { return nil }
    let pick = results.first { $0.iso31661 == region }
        ?? results.first { $0.iso31661 == "US" }
    return pick?.releaseDates?
        .compactMap { $0.certification }
        .first { !$0.isEmpty }
}

func seerrCertification(tvRatings: SeerrContentRatings?, region: String) -> String? {
    guard let results = tvRatings?.results else { return nil }
    let pick = results.first { $0.iso31661 == region }
        ?? results.first { $0.iso31661 == "US" }
    return pick?.rating.flatMap { $0.isEmpty ? nil : $0 }
}
