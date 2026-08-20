import Testing
import Foundation
@testable import Sodalite

/// A Radarr upgrade replaces a movie file the way Sonarr replaces an episode, and Jellyfin ids an item by
/// its path, so the old id dies with the old filename.
///
/// A movie has no season to enumerate, so identity comes from external ids, which is weaker. That makes
/// the order the thing worth pinning: the id has to be established as GONE before any search runs. A
/// library holding the same film twice (a 1080p and a 4K copy) would otherwise answer a transient failure
/// by handing the session the other copy.
struct ReplacedMovieRecoveryTests {

    private func movie(
        id: String,
        name: String = "Blade Runner",
        year: Int? = 1982,
        tmdb: Int? = nil
    ) throws -> JellyfinItem {
        var fields = ["\"Id\":\"\(id)\"", "\"Name\":\"\(name)\"", "\"Type\":\"Movie\""]
        if let year { fields.append("\"ProductionYear\":\(year)") }
        if let tmdb { fields.append("\"ProviderIds\":{\"Tmdb\":\"\(tmdb)\"}") }
        return try JSONDecoder().decode(JellyfinItem.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    /// `library` answers the `Ids=` existence probe, `searchResults` the title search, `providerMatch`
    /// the verified provider-id lookup.
    private struct Catalog: MovieCatalogQuerying {
        var library: [JellyfinItem] = []
        var searchResults: [JellyfinItem] = []
        var providerMatch: JellyfinItem?
        var idLookupFails = false

        func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            if let ids = query.ids {
                if idLookupFails { throw APIError.timeout }
                let hits = library.filter { ids.contains($0.id) }
                return JellyfinItemsResponse(items: hits, totalRecordCount: hits.count)
            }
            return JellyfinItemsResponse(items: searchResults, totalRecordCount: searchResults.count)
        }

        func findByProviderIDs(
            userID: String,
            tmdbID: Int?,
            tvdbID: Int?,
            imdbID: String?,
            includeItemTypes: [ItemType],
            searchTerm: String?
        ) async throws -> JellyfinItem? {
            guard tmdbID != nil || tvdbID != nil || imdbID != nil else { return nil }
            return providerMatch
        }
    }

    private func resolve(_ stale: JellyfinItem, _ catalog: Catalog) async -> JellyfinItem? {
        await ReplacedMovieResolver(service: catalog, userID: "u").replacement(for: stale)
    }

    @Test func aVanishedMovieResolvesThroughItsProviderId() async throws {
        let stale = try movie(id: "old", tmdb: 78)
        let catalog = Catalog(library: [], providerMatch: try movie(id: "new", tmdb: 78))
        #expect(await resolve(stale, catalog)?.id == "new")
    }

    /// The load-bearing one: a second copy of the same film is a provider-id match too, so without the
    /// existence probe a hiccup on the copy the user picked would silently start the other one.
    @Test func aMovieTheServerStillListsIsNeverSwappedForAnotherCopy() async throws {
        let stale = try movie(id: "old", tmdb: 78)
        let catalog = Catalog(library: [stale], providerMatch: try movie(id: "other-copy", tmdb: 78))
        #expect(await resolve(stale, catalog) == nil)
    }

    /// A failed probe is not an absent item; treating the two alike would swap items on every hiccup.
    @Test func aFailedExistenceProbeResolvesToNothing() async throws {
        let stale = try movie(id: "old", tmdb: 78)
        let catalog = Catalog(providerMatch: try movie(id: "new", tmdb: 78), idLookupFails: true)
        #expect(await resolve(stale, catalog) == nil)
    }

    /// A slim Home row carries no ProviderIds, so title plus year is the only axis left.
    @Test func aSnapshotWithoutExternalIdsFallsBackToTitleAndYear() async throws {
        let stale = try movie(id: "old")
        let catalog = Catalog(searchResults: [
            try movie(id: "new"),
            try movie(id: "unrelated", name: "Blade Runner 2049", year: 2017)
        ])
        #expect(await resolve(stale, catalog)?.id == "new")
    }

    /// Two files of the same title and year: which one replaced the dead id is not knowable, and playing
    /// the wrong film is worse than the error the user already had.
    @Test func anAmbiguousTitleMatchResolvesToNothing() async throws {
        let stale = try movie(id: "old")
        let catalog = Catalog(searchResults: [try movie(id: "new-a"), try movie(id: "new-b")])
        #expect(await resolve(stale, catalog) == nil)
    }

    /// Same title, different film.
    @Test func aTitleMatchFromAnotherYearIsRejected() async throws {
        let stale = try movie(id: "old")
        let catalog = Catalog(searchResults: [try movie(id: "remake", year: 2017)])
        #expect(await resolve(stale, catalog) == nil)
    }

    /// Without a year on the snapshot the title alone is not enough to act on.
    @Test func aSnapshotWithoutAYearDoesNotFallBackToTheTitle() async throws {
        let stale = try movie(id: "old", year: nil)
        let catalog = Catalog(searchResults: [try movie(id: "new")])
        #expect(await resolve(stale, catalog) == nil)
    }

    // MARK: - Axis pick

    private struct EmptyEpisodes: EpisodeCatalogQuerying {
        func getSeasons(seriesID: String, userID: String) async throws -> [JellyfinItem] { [] }
        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> [JellyfinItem] { [] }
    }

    /// Without an item service (live sessions, previews) a movie simply keeps its error.
    @Test func aMovieWithoutAnItemServiceResolvesToNothing() async throws {
        let resolved = await ReplacedItemResolver.replacement(
            for: try movie(id: "old", tmdb: 78),
            episodes: EmptyEpisodes(),
            movies: nil,
            userID: "u"
        )
        #expect(resolved == nil)
    }

    @Test func aMovieIsResolvedOnTheMovieAxis() async throws {
        let stale = try movie(id: "old", tmdb: 78)
        let resolved = await ReplacedItemResolver.replacement(
            for: stale,
            episodes: EmptyEpisodes(),
            movies: Catalog(providerMatch: try movie(id: "new", tmdb: 78)),
            userID: "u"
        )
        #expect(resolved?.id == "new")
    }

    /// An episode must not fall into the movie branch even with a movie catalog present: its own axis is
    /// exact, and a title search over episodes named "Pilot" is not.
    @Test func anEpisodeIsResolvedOnTheEpisodeAxis() async throws {
        let json = """
        {"Id":"ep-old","Name":"Pilot","Type":"Episode","SeriesId":"s","SeasonId":"s1","IndexNumber":1}
        """
        let stale = try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
        let resolved = await ReplacedItemResolver.replacement(
            for: stale,
            episodes: EmptyEpisodes(),
            movies: Catalog(searchResults: [try movie(id: "wrong")]),
            userID: "u"
        )
        #expect(resolved == nil)
    }
}
