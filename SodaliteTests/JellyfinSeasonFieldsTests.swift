import Testing
import Foundation
@testable import Sodalite

/// The season list is the only source of per-season episode counts, and the catalog's Jellyfin
/// ground-truth reconcile scores a season with zero episodes as deleted. Jellyfin fills a Season's
/// ChildCount only under `ItemFields.ChildCount`, so asking for `ItemCounts` (which covers the
/// ItemsByName path, not seasons) silently returned nil for every season.
@MainActor
struct JellyfinSeasonFieldsTests {
    private func fieldsValue(_ endpoint: JellyfinEndpoint) -> String? {
        endpoint.queryItems?.first { $0.name == "Fields" }?.value
    }

    @Test func seasonsEndpointRequestsChildCount() {
        let fields = fieldsValue(.seasons(seriesID: "series-1", userID: "user-1"))
        #expect(fields?.split(separator: ",").contains("ChildCount") == true)
    }

    @Test func seasonsEndpointStillCarriesTheUser() {
        let items = JellyfinEndpoint.seasons(seriesID: "series-1", userID: "user-1").queryItems ?? []
        #expect(items.first { $0.name == "UserId" }?.value == "user-1")
    }
}
