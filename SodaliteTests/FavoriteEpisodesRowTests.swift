import Testing
import Foundation
@testable import Sodalite

/// The Favorite Episodes row renders episodes, so it must ride the landscape/backdrop path that
/// Continue Watching and Next Up use (that path is what resolves an episode still instead of a
/// poster), and its query must ask the server for favorited episodes rather than filtering client
/// side.
@MainActor
struct FavoriteEpisodesRowTests {
    private func value(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first { $0.name == name }?.value
    }

    @Test func rowUsesLandscapeEpisodeArtworkPath() {
        #expect(HomeRowType.favoriteEpisodes.cardStyle == .landscape)
        #expect(HomeRowType.favoriteEpisodes.usesBackdrop)
    }

    /// Enabled by default is safe because empty rows are dropped before display, so a user without
    /// favorited episodes sees nothing rather than an empty shelf.
    @Test func rowIsEnabledByDefaultAndPresentInDefaultConfig() {
        #expect(HomeRowType.favoriteEpisodes.defaultEnabled)
        #expect(HomeRowConfig.defaultConfig().contains { $0.type == .favoriteEpisodes })
    }

    /// Distinct from the Favorites row's own icon, else the two are indistinguishable in Customize.
    @Test func rowHasItsOwnIcon() {
        #expect(HomeRowType.favoriteEpisodes.systemImage != HomeRowType.favorites.systemImage)
    }

    /// Query contract of the row: episodes only, server-side favorite filter, grouped by series then
    /// season then episode so several favorites of one show stay adjacent.
    @Test func rowQueryAsksForFavoritedEpisodes() {
        let query = ItemQuery(
            includeItemTypes: [.episode],
            sortBy: "SeriesSortName,ParentIndexNumber,IndexNumber",
            sortOrder: "Ascending",
            limit: 30,
            isFavorite: true,
            fields: JellyfinEndpoint.homeRowFields
        )
        let items = query.toQueryItems()
        #expect(value(items, "IncludeItemTypes") == "Episode")
        #expect(value(items, "IsFavorite") == "true")
        #expect(value(items, "SortBy") == "SeriesSortName,ParentIndexNumber,IndexNumber")
        #expect(value(items, "Limit") == "30")
        // Library-wide episode lookup relies on the always-on Recursive flag, no ParentId needed.
        #expect(value(items, "Recursive") == "true")
        #expect(!items.contains { $0.name == "ParentId" })
    }
}
