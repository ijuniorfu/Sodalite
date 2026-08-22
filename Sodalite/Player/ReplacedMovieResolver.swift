import Foundation

/// What resolving a replaced movie needs: an id lookup to establish that the old item is really gone,
/// and a provider-id search to find what took its place. A narrow face on the item service so the
/// resolver is exercised without the rest of it.
protocol MovieCatalogQuerying: Sendable {
    func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse
    /// Resolves a library item across several external ids (tmdb, then tvdb/imdb fallbacks). Jellyfin
    /// cannot filter by provider id, so `searchTerm` narrows the candidates and each one is verified
    /// against the ids; nil means no candidate carried them, which is NOT proof of absence when the title
    /// search itself missed. Throws on query failure so callers can tell a miss from a failure.
    func findByProviderIDs(
        userID: String,
        tmdbID: Int?,
        tvdbID: Int?,
        imdbID: String?,
        includeItemTypes: [ItemType],
        searchTerm: String?
    ) async throws -> JellyfinItem?
}

/// Radarr upgrades a movie the same way Sonarr upgrades an episode, and because Jellyfin ids an item by
/// its path the result is the same: a new item, and a dead id in everything the app is holding.
///
/// A movie has no series/season/number axis, so identity has to come from somewhere weaker, and that
/// makes the ORDER load-bearing. The id is established as gone first, by asking for it directly. Only
/// then does a search run. Without that order a library holding the same film twice (a 1080p and a 4K
/// copy) would hand the session the other copy on any transient failure, and an error would have been
/// the better answer.
struct ReplacedMovieResolver: Sendable {
    let service: MovieCatalogQuerying
    let userID: String
    /// Candidate cap for the title search; the same order of magnitude the provider-id lookup uses.
    private static let candidateLimit = 20

    func replacement(for stale: JellyfinItem) async -> JellyfinItem? {
        guard stale.type == .movie else { return nil }
        // A failed query throws and lands here as nil, which is not the same answer as an empty result:
        // only a query that came back and did NOT contain the id proves the id is gone.
        guard let stillListed = try? await isStillListed(stale.id), !stillListed else { return nil }

        if let match = try? await matchByProviderIDs(stale), match.id != stale.id {
            return match
        }
        return try? await uniqueTitleMatch(for: stale)
    }

    private func isStillListed(_ id: String) async throws -> Bool {
        let response = try await service.getCollectionItems(
            userID: userID,
            // Presence check only: the response is scanned for the id and thrown away.
            query: ItemQuery(ids: [id], limit: 1, fields: "")
        )
        return response.items.contains { $0.id == id }
    }

    private func matchByProviderIDs(_ stale: JellyfinItem) async throws -> JellyfinItem? {
        try await service.findByProviderIDs(
            userID: userID,
            tmdbID: stale.tmdbID,
            tvdbID: stale.tvdbID,
            imdbID: stale.imdbID,
            includeItemTypes: [.movie],
            searchTerm: stale.name
        )
    }

    /// Fallback for a snapshot that carries no external ids (a slim Home row does not): same title, same
    /// production year, and only when exactly ONE candidate matches. An ambiguous library keeps its error
    /// rather than playing a different film.
    private func uniqueTitleMatch(for stale: JellyfinItem) async throws -> JellyfinItem? {
        guard let year = stale.productionYear else { return nil }
        let response = try await service.getCollectionItems(
            userID: userID,
            query: ItemQuery(
                includeItemTypes: [.movie],
                limit: Self.candidateLimit,
                searchTerm: stale.name,
                // The match is returned to a live player session, so it needs the playback fields.
                fields: JellyfinEndpoint.detailFields
            )
        )
        let matches = response.items.filter {
            $0.id != stale.id
                && $0.productionYear == year
                && $0.name.caseInsensitiveCompare(stale.name) == .orderedSame
        }
        return matches.count == 1 ? matches.first : nil
    }
}

/// Picks the axis a vanished item can be resolved on: an episode by its number inside the season, a
/// movie by its external ids. Nothing else is resolvable, and nothing else is guessed at.
enum ReplacedItemResolver {
    static func replacement(
        for stale: JellyfinItem,
        episodes: EpisodeCatalogQuerying,
        movies: MovieCatalogQuerying?,
        userID: String
    ) async -> JellyfinItem? {
        if stale.seriesId != nil {
            return await ReplacedEpisodeResolver(service: episodes, userID: userID).replacement(for: stale)
        }
        guard stale.type == .movie, let movies else { return nil }
        return await ReplacedMovieResolver(service: movies, userID: userID).replacement(for: stale)
    }
}
