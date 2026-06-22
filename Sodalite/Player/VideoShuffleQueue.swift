import Foundation

/// Builds a shuffled play queue from a `SortBy=Random` query for the shuffle
/// buttons. ItemQuery always sends `Recursive=true`, so a series id returns
/// random episodes across seasons and a folder returns random leaf items.
enum VideoShuffleQueue {

    /// Queue cap; 200 = hundreds of hours, so no refill on reaching the end.
    static let defaultLimit = 200

    /// Fetches up to `limit` random `itemTypes` under `parentID`. `baseQuery`
    /// (if given) is the starting query with sort/type/paging/filter
    /// overridden. Empty array on any failure (caller no-ops).
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
