import Foundation

/// Builds a shuffled play queue from a Jellyfin `SortBy=Random` query.
/// Used by the video shuffle buttons on series / collection / library
/// surfaces. `ItemQuery.toQueryItems()` always sends `Recursive=true`,
/// so a series id returns random episodes across all seasons and a
/// library folder returns random leaf items across the whole library.
enum VideoShuffleQueue {

    /// Default queue cap. 200 items is hundreds of hours; reaching the
    /// end in one session isn't a real case, so there's no refill.
    static let defaultLimit = 200

    /// Fetches up to `limit` random items of `itemTypes` under
    /// `parentID`. `baseQuery`, when supplied, is used as the starting
    /// query (preserving e.g. the library grid's parentID) with the
    /// sort / type / paging / filter fields overridden for shuffle.
    /// Returns an empty array on any failure (the caller no-ops).
    static func build(
        parentID: String?,
        baseQuery: ItemQuery? = nil,
        itemTypes: [ItemType],
        limit: Int = defaultLimit,
        service: JellyfinLibraryServiceProtocol,
        userID: String
    ) async -> [JellyfinItem] {
        var query = baseQuery ?? ItemQuery()
        if let parentID { query.parentID = parentID }
        query.includeItemTypes = itemTypes
        query.sortBy = "Random"
        query.sortOrder = nil
        query.limit = limit
        query.startIndex = nil
        // Shuffle ignores the watch-status filter per the feature spec.
        query.filters = nil
        let response = try? await service.getItems(userID: userID, query: query)
        return response?.items ?? []
    }
}
