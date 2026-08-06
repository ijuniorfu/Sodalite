import Testing
import Foundation
@testable import Sodalite

/// The guide's channel filters are the one place where a wrong query name fails silently: the
/// server ignores an unknown parameter and returns everything, which reads as "the filter does
/// nothing" rather than as an error.
struct GuideFilterTests {

    private func value(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first(where: { $0.name == name })?.value
    }

    @Test("the default filter asks for TV channels and nothing else")
    func defaultFilter() {
        let items = GuideFilter.default.queryItems
        #expect(value(items, "Type") == "TV")
        #expect(value(items, "IsFavorite") == nil)
        #expect(items.count == 1)
        #expect(GuideFilter.default.isDefault)
    }

    /// The Live TV tab gate asks "does this server have channels at all". Restricting that probe to
    /// Type=TV would hide the whole tab from a server whose tuners are radio only.
    @Test("the any filter sends no Type at all")
    func anyFilter() {
        #expect(GuideFilter.any.queryItems.isEmpty)
        #expect(!GuideFilter.any.isDefault)
    }

    @Test("favorites only adds IsFavorite")
    func favorites() {
        var filter = GuideFilter.default
        filter.favoritesOnly = true
        #expect(value(filter.queryItems, "IsFavorite") == "true")
        #expect(!filter.isDefault)
    }

    @Test("each category maps to the parameter Jellyfin actually reads")
    func categoryNames() {
        #expect(GuideFilter.Category.sports.queryName == "IsSports")
        #expect(GuideFilter.Category.kids.queryName == "IsKids")
        #expect(GuideFilter.Category.news.queryName == "IsNews")
        #expect(GuideFilter.Category.movies.queryName == "IsMovie")
    }

    @Test("only the selected category is sent, never a second one")
    func singleCategory() {
        var filter = GuideFilter.default
        filter.category = .kids
        let items = filter.queryItems
        #expect(value(items, "IsKids") == "true")
        for other in GuideFilter.Category.allCases where other != .kids {
            #expect(value(items, other.queryName) == nil)
        }
    }

    @Test("favorites, category and kind combine in one query")
    func combined() {
        var filter = GuideFilter.default
        filter.favoritesOnly = true
        filter.category = .sports
        filter.kind = .radio
        let items = filter.queryItems
        #expect(value(items, "Type") == "Radio")
        #expect(value(items, "IsFavorite") == "true")
        #expect(value(items, "IsSports") == "true")
    }

    @Test("the endpoint merges filter items into the channel query")
    func endpointMergesFilter() {
        var filter = GuideFilter.default
        filter.favoritesOnly = true
        let endpoint = JellyfinEndpoint.liveTvChannels(
            userID: "u1", startIndex: 0, limit: 200, filter: filter)
        let items = endpoint.queryItems ?? []
        #expect(value(items, "IsFavorite") == "true")
        #expect(value(items, "Type") == "TV")
        // The base items the guide has always relied on must survive the merge.
        #expect(value(items, "AddCurrentProgram") == "true")
        #expect(value(items, "EnableFavoriteSorting") == "true")
        #expect(value(items, "EnableUserData") == "true")
        #expect(value(items, "Limit") == "200")
        #expect(value(items, "StartIndex") == "0")
        #expect(value(items, "UserId") == "u1")
    }
}
