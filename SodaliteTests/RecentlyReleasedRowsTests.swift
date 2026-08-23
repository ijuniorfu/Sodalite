import Testing
import Foundation
@testable import Sodalite

/// The Recently Released rows sort by when a title aired or premiered, not by when the file landed
/// on the server, which is what every existing Latest row does. Sorting by `PremiereDate` alone
/// would surface titles that have not aired yet: Jellyfin lists unaired episodes as virtual items
/// when the admin enables "display missing episodes", and those carry a future premiere date. The
/// row therefore clamps the query with `MaxPremiereDate`, asks the server to drop file-less
/// episodes, and still filters virtual items out of what comes back, because `IsMissing` covers
/// missing but not unaired ones (same reason `PersonLibrary` re-filters, Sodalite#57).
struct RecentlyReleasedRowsTests {
    private func value(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first { $0.name == name }?.value
    }

    private let reference = Date(timeIntervalSince1970: 1_774_000_000)  // 2026-03-20T09:46:40Z

    // MARK: - Query clamp

    @Test func queryEncodesMaxPremiereDateAsISO8601() {
        let query = ItemQuery(
            includeItemTypes: [.movie],
            maxPremiereDate: reference,
            fields: JellyfinEndpoint.homeRowFields
        )
        #expect(value(query.toQueryItems(), "MaxPremiereDate") == "2026-03-20T09:46:40Z")
    }

    @Test func queryOmitsMaxPremiereDateWhenUnset() {
        let query = ItemQuery(includeItemTypes: [.movie], fields: "")
        #expect(!query.toQueryItems().contains { $0.name == "MaxPremiereDate" })
    }

    // MARK: - Row queries

    @Test func moviesQueryOrdersByReleaseDateAndClampsToNow() {
        let items = HomeReleaseRowQuery.movies(now: reference, limit: 20).toQueryItems()
        #expect(value(items, "IncludeItemTypes") == "Movie")
        #expect(value(items, "SortBy") == "PremiereDate,ProductionYear,SortName")
        #expect(value(items, "SortOrder") == "Descending")
        #expect(value(items, "MaxPremiereDate") == "2026-03-20T09:46:40Z")
        #expect(value(items, "Limit") == "20")
        #expect(value(items, "Recursive") == "true")
    }

    /// A series' own `PremiereDate` is the date the show started, so sorting series by it buries a
    /// long-running show that aired an episode last night. The row asks for episodes and folds them
    /// onto their series instead.
    @Test func showsQueryAsksForAiredEpisodesNotSeries() {
        let items = HomeReleaseRowQuery.episodes(now: reference, limit: 64).toQueryItems()
        #expect(value(items, "IncludeItemTypes") == "Episode")
        #expect(value(items, "SortBy") == "PremiereDate")
        #expect(value(items, "SortOrder") == "Descending")
        #expect(value(items, "MaxPremiereDate") == "2026-03-20T09:46:40Z")
        #expect(value(items, "IsMissing") == "false")
    }

    /// Folding several episodes of one series into a single tile shrinks the list, so the query has
    /// to ask for more than the row shows (same rationale as the Latest Shows row).
    @Test func showsQueryOverFetchesToSurviveFolding() {
        #expect(HomeReleaseRowQuery.episodes(now: reference, limit: 64).limit == 64)
        #expect(HomeReleaseRowQuery.movies(now: reference, limit: 20).limit == 20)
    }

    // MARK: - Virtual item filter

    private func item(_ id: String, locationType: String? = nil) -> JellyfinItem {
        var item = JellyfinItem(seriesStub: id, name: id)
        item.locationType = locationType
        return item
    }

    @Test func airedOnlyDropsVirtualItems() {
        let items = [item("aired"), item("unaired", locationType: "Virtual")]
        #expect(HomeReleaseRowQuery.airedOnly(items).map(\.id) == ["aired"])
    }

    @Test func airedOnlyKeepsOrder() {
        let items = [
            item("newest"),
            item("unaired", locationType: "Virtual"),
            item("older"),
        ]
        #expect(HomeReleaseRowQuery.airedOnly(items).map(\.id) == ["newest", "older"])
    }

    // MARK: - Row configuration

    @Test func rowsAreOptInButReachExistingUsers() {
        #expect(!HomeRowType.recentlyReleasedMovies.defaultEnabled)
        #expect(!HomeRowType.recentlyReleasedShows.defaultEnabled)
        // reconciled() appends types missing from a stored config, so an existing install finds them
        // in Customize without hitting Reset.
        let reconciled = HomeRowConfig.reconciled(
            stored: [HomeRowConfig(type: .continueWatching, isEnabled: true, sortOrder: 0)],
            libraries: []
        )
        #expect(reconciled.contains { $0.type == .recentlyReleasedMovies })
        #expect(reconciled.contains { $0.type == .recentlyReleasedShows })
    }

    /// Distinct titles are the whole point of the split: "Latest" already means recently added.
    @Test func rowTitlesDifferFromTheLatestRows() {
        #expect(HomeRowType.recentlyReleasedMovies.localizedTitle != HomeRowType.latestMovies.localizedTitle)
        #expect(HomeRowType.recentlyReleasedShows.localizedTitle != HomeRowType.latestShows.localizedTitle)
        #expect(HomeRowType.recentlyReleasedMovies.localizedTitle != HomeRowType.recentlyAdded.localizedTitle)
    }
}
