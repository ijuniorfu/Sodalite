import Foundation

protocol JellyfinMusicServiceProtocol: Sendable {
    /// All music albums on the server, sorted by name.
    func getAlbums(userID: String) async throws -> [JellyfinItem]
    /// Tracks in an album, sorted by disc then track number.
    func getSongs(userID: String, albumID: String) async throws -> [JellyfinItem]
    /// True when the server has at least one library whose
    /// collectionType is "music".
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
        var query = ItemQuery()
        query.includeItemTypes = [.musicAlbum]
        query.sortBy = "SortName"
        query.sortOrder = "Ascending"
        query.fields = JellyfinEndpoint.musicListFields
        let response: JellyfinItemsResponse = try await client.request(
            endpoint: JellyfinEndpoint.items(userID: userID, query: query),
            responseType: JellyfinItemsResponse.self
        )
        return response.items
    }

    func getSongs(userID: String, albumID: String) async throws -> [JellyfinItem] {
        var query = ItemQuery()
        query.parentID = albumID
        query.includeItemTypes = [.audio]
        query.sortBy = "ParentIndexNumber,IndexNumber"
        query.sortOrder = "Ascending"
        query.fields = JellyfinEndpoint.musicListFields
        let response: JellyfinItemsResponse = try await client.request(
            endpoint: JellyfinEndpoint.items(userID: userID, query: query),
            responseType: JellyfinItemsResponse.self
        )
        // The server SortBy above is not reliably honored for album tracks
        // (single-disc albums commonly carry a null ParentIndexNumber, which
        // makes the multi-key server sort fall back to an arbitrary order).
        // Sort client-side by disc, then track number, then title so the
        // queue and tracklist are always in album order. Untagged tracks
        // (nil index) sort last, ordered by name.
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
        let libraries = try await libraryService.getLibraries(userID: userID)
        return libraries.contains { $0.collectionType == "music" }
    }
}
