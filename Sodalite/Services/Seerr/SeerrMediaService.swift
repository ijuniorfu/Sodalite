import Foundation

protocol SeerrMediaServiceProtocol: Sendable {
    func movieDetail(tmdbID: Int) async throws -> SeerrMovieDetail
    func tvDetail(tmdbID: Int) async throws -> SeerrTVDetail
    func tvSeasonDetail(tmdbID: Int, seasonNumber: Int) async throws -> SeerrSeasonDetail
    func recommendations(mediaType: SeerrMediaType, tmdbID: Int) async throws -> [SeerrMedia]
    func similar(mediaType: SeerrMediaType, tmdbID: Int) async throws -> [SeerrMedia]
    func personDetail(tmdbID: Int) async throws -> SeerrPersonDetail
    func personCredits(tmdbID: Int) async throws -> SeerrPersonCredits

    /// Removes the Radarr database entry for the movie with the given
    /// TMDB id. Returns true if a Seerr media record was found and the
    /// delete call was made, false if no Seerr record exists (treated
    /// as a successful no-op by the deletion service).
    func removeMovieFromRadarr(tmdbID: Int) async throws -> Bool

    /// Same as `removeMovieFromRadarr` for series.
    func removeSeriesFromSonarr(tmdbID: Int) async throws -> Bool
}

@MainActor
final class SeerrMediaService: SeerrMediaServiceProtocol {
    private let client: SeerrClient

    init(client: SeerrClient) {
        self.client = client
    }

    func movieDetail(tmdbID: Int) async throws -> SeerrMovieDetail {
        try await client.request(
            endpoint: SeerrEndpoint.movieDetail(tmdbID: tmdbID),
            responseType: SeerrMovieDetail.self
        )
    }

    func tvDetail(tmdbID: Int) async throws -> SeerrTVDetail {
        try await client.request(
            endpoint: SeerrEndpoint.tvDetail(tmdbID: tmdbID),
            responseType: SeerrTVDetail.self
        )
    }

    func tvSeasonDetail(tmdbID: Int, seasonNumber: Int) async throws -> SeerrSeasonDetail {
        try await client.request(
            endpoint: SeerrEndpoint.tvSeasonDetail(tmdbID: tmdbID, seasonNumber: seasonNumber),
            responseType: SeerrSeasonDetail.self
        )
    }

    func recommendations(mediaType: SeerrMediaType, tmdbID: Int) async throws -> [SeerrMedia] {
        let endpoint: SeerrEndpoint
        switch mediaType {
        case .movie: endpoint = .movieRecommendations(tmdbID: tmdbID, page: 1)
        case .tv: endpoint = .tvRecommendations(tmdbID: tmdbID, page: 1)
        case .person, .unknown: return []
        }
        let result = try await client.request(
            endpoint: endpoint,
            responseType: SeerrDiscoverResult.self
        )
        return result.results.filter { $0.mediaType == .movie || $0.mediaType == .tv }
    }

    func similar(mediaType: SeerrMediaType, tmdbID: Int) async throws -> [SeerrMedia] {
        let endpoint: SeerrEndpoint
        switch mediaType {
        case .movie: endpoint = .movieSimilar(tmdbID: tmdbID, page: 1)
        case .tv: endpoint = .tvSimilar(tmdbID: tmdbID, page: 1)
        case .person, .unknown: return []
        }
        let result = try await client.request(
            endpoint: endpoint,
            responseType: SeerrDiscoverResult.self
        )
        return result.results.filter { $0.mediaType == .movie || $0.mediaType == .tv }
    }

    func personDetail(tmdbID: Int) async throws -> SeerrPersonDetail {
        try await client.request(
            endpoint: SeerrEndpoint.personDetail(tmdbID: tmdbID),
            responseType: SeerrPersonDetail.self
        )
    }

    func personCredits(tmdbID: Int) async throws -> SeerrPersonCredits {
        try await client.request(
            endpoint: SeerrEndpoint.personCombinedCredits(tmdbID: tmdbID),
            responseType: SeerrPersonCredits.self
        )
    }

    func removeMovieFromRadarr(tmdbID: Int) async throws -> Bool {
        // Resolve TMDB id → Seerr media id. movieDetail returns
        // mediaInfo.id only when Seerr has a record (the movie was
        // requested through Seerr or detected via library scan). If
        // mediaInfo is nil, there's nothing for Seerr to remove.
        let detail = try await movieDetail(tmdbID: tmdbID)
        guard let seerrMediaID = detail.mediaInfo?.id else { return false }
        try await client.request(
            endpoint: SeerrEndpoint.mediaFileDelete(seerrMediaID: seerrMediaID)
        )
        return true
    }

    func removeSeriesFromSonarr(tmdbID: Int) async throws -> Bool {
        let detail = try await tvDetail(tmdbID: tmdbID)
        guard let seerrMediaID = detail.mediaInfo?.id else { return false }
        try await client.request(
            endpoint: SeerrEndpoint.mediaFileDelete(seerrMediaID: seerrMediaID)
        )
        return true
    }
}
