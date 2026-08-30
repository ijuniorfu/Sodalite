import Foundation

protocol JellyfinMusicServiceProtocol: Sendable {
    /// All music albums on the server, sorted by name.
    func getAlbums(userID: String) async throws -> [JellyfinItem]
    /// Tracks in an album, sorted by disc then track number.
    func getSongs(userID: String, albumID: String) async throws -> [JellyfinItem]
    /// Every track in the server's music libraries, name-sorted, capped at `limit`.
    ///
    /// The album grid's fallback, and the only route to a track that belongs to no album. Jellyfin
    /// builds `MusicAlbum` from folder boundaries rather than from the tracks' `Album` tag, so a
    /// library whose files sit in one flat folder holds `Audio` items and no albums at all, and this
    /// app reached music through albums exclusively (Sodalite#88).
    func getAllSongs(userID: String, limit: Int) async throws -> [JellyfinItem]
    /// True when at least one library has collectionType "music".
    func hasMusicLibrary(userID: String) async throws -> Bool
}

final class JellyfinMusicService: JellyfinMusicServiceProtocol {
    private let client: JellyfinClient
    private let libraryService: JellyfinLibraryServiceProtocol

    init(client: JellyfinClient, libraryService: JellyfinLibraryServiceProtocol) {
        self.client = client
        self.libraryService = libraryService
    }

    func getAlbums(userID: String) async throws -> [JellyfinItem] {
        var query = ItemQuery(fields: JellyfinEndpoint.musicListFields)
        query.includeItemTypes = [.musicAlbum]
        query.sortBy = "SortName"
        query.sortOrder = "Ascending"
        let response: JellyfinItemsResponse = try await client.request(
            endpoint: JellyfinEndpoint.items(userID: userID, query: query),
            responseType: JellyfinItemsResponse.self
        )
        // The one outcome an empty grid cannot explain by itself (Sodalite#88). A total above zero
        // means the server holds albums and the lenient element decode dropped every one of them; a
        // total of zero means this query is not the one that finds them, and then the next question
        // is what was asked, so the query shape rides along.
        if response.items.isEmpty {
            LogTap.shared.note(
                "[music] getAlbums empty: total=\(response.totalRecordCount) query=\(Self.rendered(query))"
            )
        }
        return response.items
    }

    /// Typed, scoped and capped. Typed because a music library also carries its folders, scoped
    /// because `Audio` outside a music library is somebody's audiobook, capped because an unbounded
    /// track list is a page nobody scrolls.
    static func allSongsQuery(libraryID: String, limit: Int) -> ItemQuery {
        var query = ItemQuery(fields: JellyfinEndpoint.musicListFields)
        query.parentID = libraryID
        query.includeItemTypes = [.audio]
        query.sortBy = "SortName"
        query.sortOrder = "Ascending"
        query.limit = limit
        return query
    }

    func getAllSongs(userID: String, limit: Int) async throws -> [JellyfinItem] {
        let libraryIDs = try await musicLibraryIDs(userID: userID)
        guard !libraryIDs.isEmpty else {
            LogTap.shared.note("[music] all songs: no music library to ask")
            return []
        }
        var collected: [JellyfinItem] = []
        var available = 0
        for libraryID in libraryIDs {
            let response: JellyfinItemsResponse = try await client.request(
                endpoint: JellyfinEndpoint.items(
                    userID: userID,
                    query: Self.allSongsQuery(libraryID: libraryID, limit: limit)
                ),
                responseType: JellyfinItemsResponse.self
            )
            collected.append(contentsOf: response.items)
            available += response.totalRecordCount
        }
        // Server SortBy orders each library on its own; the merge across libraries is ours, and
        // getSongs already found the server's ordering not worth trusting on its own.
        let sorted = collected.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        let shown = Array(sorted.prefix(limit))
        // A cap that stays quiet reads as "this is everything" (Sodalite#88 was a silent empty).
        if available > shown.count {
            LogTap.shared.note("[music] all songs: showing \(shown.count) of \(available), capped at \(limit)")
        } else {
            LogTap.shared.note("[music] all songs: \(shown.count) returned")
        }
        return shown
    }

    private func musicLibraryIDs(userID: String) async throws -> [String] {
        try await libraryService.getLibraries(userID: userID)
            .filter { $0.collectionType == "music" }
            .map(\.id)
    }

    private static func rendered(_ query: ItemQuery) -> String {
        query.toQueryItems()
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")
    }

    func getSongs(userID: String, albumID: String) async throws -> [JellyfinItem] {
        var query = ItemQuery(fields: JellyfinEndpoint.musicListFields)
        query.parentID = albumID
        query.includeItemTypes = [.audio]
        query.sortBy = "ParentIndexNumber,IndexNumber"
        query.sortOrder = "Ascending"
        let response: JellyfinItemsResponse = try await client.request(
            endpoint: JellyfinEndpoint.items(userID: userID, query: query),
            responseType: JellyfinItemsResponse.self
        )
        // Re-sort client-side: server SortBy is unreliable for tracks (single-disc albums often have null ParentIndexNumber → arbitrary order). Disc → track → title; untagged (nil index) last.
        return response.items.sorted { a, b in
            let discA = a.parentIndexNumber ?? 0
            let discB = b.parentIndexNumber ?? 0
            if discA != discB { return discA < discB }
            let trackA = a.indexNumber ?? Int.max
            let trackB = b.indexNumber ?? Int.max
            if trackA != trackB { return trackA < trackB }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    func hasMusicLibrary(userID: String) async throws -> Bool {
        try await !musicLibraryIDs(userID: userID).isEmpty
    }
}
