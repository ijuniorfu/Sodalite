import Foundation

protocol JellyfinItemServiceProtocol: Sendable {
    func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem
    /// Local trailers; bare array response (not the {Items:[...]} envelope), possibly empty.
    func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem]
    func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse
    func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse
    func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse
    func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws
    func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws
    func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse
    /// Resolves a library item by TMDB id via `AnyProviderIdEquals`; first match or nil.
    func findByTmdbID(userID: String, tmdbID: Int) async throws -> JellyfinItem?
    /// Resolves a library item across several external ids (tmdb, then tvdb/imdb fallbacks), first hit wins. nil only when every supplied id misses, i.e. a confident "not in this library". Throws on query failure so callers can degrade to "trust Seerr" rather than a false absence.
    func findByProviderIDs(userID: String, tmdbID: Int?, tvdbID: Int?, imdbID: String?, includeItemTypes: [ItemType]) async throws -> JellyfinItem?
    func deleteItem(itemID: String) async throws
}

final class JellyfinItemService: JellyfinItemServiceProtocol {
    private let client: JellyfinClient

    init(client: JellyfinClient) {
        self.client = client
    }

    func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem {
        try await client.request(
            endpoint: JellyfinEndpoint.itemDetail(userID: userID, itemID: itemID),
            responseType: JellyfinItem.self
        )
    }

    func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] {
        let response: LossyJellyfinItems = try await client.request(
            endpoint: JellyfinEndpoint.localTrailers(userID: userID, itemID: itemID),
            responseType: LossyJellyfinItems.self
        )
        return response.elements
    }

    func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse {
        try await client.request(
            endpoint: JellyfinEndpoint.seasons(seriesID: seriesID, userID: userID),
            responseType: JellyfinItemsResponse.self
        )
    }

    func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse {
        try await client.request(
            endpoint: JellyfinEndpoint.episodes(seriesID: seriesID, seasonID: seasonID, userID: userID),
            responseType: JellyfinItemsResponse.self
        )
    }

    func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse {
        try await client.request(
            endpoint: JellyfinEndpoint.similarItems(itemID: itemID, userID: userID, limit: limit),
            responseType: JellyfinItemsResponse.self
        )
    }

    func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
        try await client.request(
            endpoint: JellyfinEndpoint.items(userID: userID, query: query),
            responseType: JellyfinItemsResponse.self
        )
    }

    func findByTmdbID(userID: String, tmdbID: Int) async throws -> JellyfinItem? {
        let query = ItemQuery(
            includeItemTypes: [.movie, .series],
            limit: 1,
            anyProviderIdEquals: "tmdb.\(tmdbID)"
        )
        let response = try await getCollectionItems(userID: userID, query: query)
        return response.items.first
    }

    func findByProviderIDs(
        userID: String,
        tmdbID: Int?,
        tvdbID: Int?,
        imdbID: String?,
        includeItemTypes: [ItemType]
    ) async throws -> JellyfinItem? {
        // AnyProviderIdEquals takes one value per query, so try each id in turn and short-circuit on the first hit (tmdb usually matches movies in one call; Sonarr/TVDB-scanned series fall through to tvdb).
        var values: [String] = []
        if let tmdbID { values.append("tmdb.\(tmdbID)") }
        if let tvdbID { values.append("tvdb.\(tvdbID)") }
        if let imdbID, !imdbID.isEmpty { values.append("imdb.\(imdbID)") }

        for value in values {
            let query = ItemQuery(
                includeItemTypes: includeItemTypes,
                limit: 1,
                anyProviderIdEquals: value
            )
            if let hit = try await getCollectionItems(userID: userID, query: query).items.first {
                return hit
            }
        }
        return nil
    }

    func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {
        let endpoint: JellyfinEndpoint = isFavorite
            ? .markFavorite(userID: userID, itemID: itemID)
            : .unmarkFavorite(userID: userID, itemID: itemID)
        try await client.request(endpoint: endpoint)
    }

    func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws {
        let endpoint: JellyfinEndpoint = isPlayed
            ? .markPlayed(userID: userID, itemID: itemID)
            : .unmarkPlayed(userID: userID, itemID: itemID)
        try await client.request(endpoint: endpoint)
    }

    func deleteItem(itemID: String) async throws {
        try await client.request(endpoint: JellyfinEndpoint.deleteItem(itemID: itemID))
    }
}
