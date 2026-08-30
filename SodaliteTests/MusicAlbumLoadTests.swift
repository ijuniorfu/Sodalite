import Testing
import Foundation
@testable import Sodalite

/// Sodalite#88: the Music tab reported "No albums found" for a library full of albums, because
/// `try? ... ?? []` turned every failure into an empty array. Empty and failed are different states
/// and must render differently, the same rule Home follows for its rows.
@MainActor
struct MusicAlbumLoadTests {

    private struct Boom: Error {}

    final class MusicSpy: JellyfinMusicServiceProtocol, @unchecked Sendable {
        var albums: [JellyfinItem] = []
        var songs: [JellyfinItem] = []
        var looseTracks: [JellyfinItem] = []
        var error: Error?
        var looseTrackError: Error?
        private(set) var albumRequests: [String] = []
        private(set) var songRequests: [String] = []
        private(set) var looseTrackRequests: [Int] = []

        func getAlbums(userID: String) async throws -> [JellyfinItem] {
            albumRequests.append(userID)
            if let error { throw error }
            return albums
        }

        func getSongs(userID: String, albumID: String) async throws -> [JellyfinItem] {
            songRequests.append(albumID)
            if let error { throw error }
            return songs
        }

        func getAllSongs(userID: String, limit: Int) async throws -> [JellyfinItem] {
            looseTrackRequests.append(limit)
            if let looseTrackError { throw looseTrackError }
            return looseTracks
        }

        func hasMusicLibrary(userID: String) async throws -> Bool { true }
    }

    private func album(_ id: String) throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"Album \#(id)","Type":"MusicAlbum"}"#.utf8)
        )
    }

    private func track(_ id: String) throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"Track \#(id)","Type":"Audio"}"#.utf8)
        )
    }

    @Test func aFailedFetchIsNotAnEmptyLibrary() async throws {
        let spy = MusicSpy()
        spy.error = APIError.httpError(statusCode: 400, data: nil)

        let vm = MusicHomeViewModel()
        await vm.load(service: spy, userID: "u")

        #expect(vm.albums.isEmpty)
        #expect(vm.displayedError != nil)
        #expect(vm.isLoading == false)
    }

    @Test func anEmptyLibraryReportsNoError() async throws {
        let vm = MusicHomeViewModel()
        await vm.load(service: MusicSpy(), userID: "u")

        #expect(vm.albums.isEmpty)
        #expect(vm.errorMessage == nil)
        #expect(vm.displayedError == nil)
    }

    @Test func aSuccessfulReloadClearsAnEarlierError() async throws {
        let spy = MusicSpy()
        spy.error = Boom()

        let vm = MusicHomeViewModel()
        await vm.load(service: spy, userID: "u")
        #expect(vm.displayedError != nil)

        spy.error = nil
        spy.albums = [try album("a")]
        await vm.load(service: spy, userID: "u")

        #expect(vm.albums.map(\.id) == ["a"])
        #expect(vm.errorMessage == nil)
    }

    /// A transient hiccup must not empty a tab that already has content, so the error screen only
    /// takes over when there is nothing else to show.
    @Test func aFailedReloadKeepsTheGridOnScreen() async throws {
        let spy = MusicSpy()
        spy.albums = [try album("a")]

        let vm = MusicHomeViewModel()
        await vm.load(service: spy, userID: "u")

        spy.error = Boom()
        await vm.load(service: spy, userID: "u")

        #expect(vm.albums.map(\.id) == ["a"])
        #expect(vm.errorMessage != nil)
        #expect(vm.displayedError == nil)
    }

    @Test func withoutAnActiveUserNothingIsRequested() async {
        let spy = MusicSpy()
        let vm = MusicHomeViewModel()
        await vm.load(service: spy, userID: nil)

        #expect(spy.albumRequests.isEmpty)
        #expect(vm.isLoading == false)
        #expect(vm.errorMessage == nil)
    }

    /// The tracklist swallowed the same way: a failed fetch drew a cover and a Play button over an
    /// empty list and said nothing.
    @Test func aFailedSongFetchIsNotAnAlbumWithoutTracks() async {
        let spy = MusicSpy()
        spy.error = APIError.timeout

        let vm = AlbumDetailViewModel()
        await vm.load(albumID: "alb", service: spy, userID: "u")

        #expect(vm.songs.isEmpty)
        #expect(vm.displayedError != nil)
        #expect(spy.songRequests == ["alb"])
    }

    // MARK: - Loose tracks (Sodalite#88 follow-up)

    /// Jellyfin builds `MusicAlbum` from folder boundaries, not from the tracks' Album tag, so a
    /// library whose files sit in one flat folder holds `Audio` items and no albums at all. Every
    /// route into music in this app went through an album, which made those tracks unreachable.
    @Test func aLibraryWithoutAlbumsFallsBackToItsTracks() async throws {
        let spy = MusicSpy()
        spy.looseTracks = [try track("t1"), try track("t2")]

        let vm = MusicHomeViewModel()
        await vm.load(service: spy, userID: "u")

        #expect(vm.albums.isEmpty)
        #expect(vm.songs.map(\.id) == ["t1", "t2"])
        #expect(vm.displayedError == nil)
        #expect(spy.looseTrackRequests.count == 1)
    }

    /// The fallback is for the one case that has no other answer. A library that returns albums must
    /// not pay for a second query.
    @Test func albumsSuppressTheTrackFallback() async throws {
        let spy = MusicSpy()
        spy.albums = [try album("a")]
        spy.looseTracks = [try track("t1")]

        let vm = MusicHomeViewModel()
        await vm.load(service: spy, userID: "u")

        #expect(vm.songs.isEmpty)
        #expect(spy.looseTrackRequests.isEmpty)
    }

    /// A thrown album request is not an album-less library, so it must not be answered with tracks.
    @Test func aFailedAlbumFetchDoesNotFallBack() async {
        let spy = MusicSpy()
        spy.error = APIError.httpError(statusCode: 500, data: nil)

        let vm = MusicHomeViewModel()
        await vm.load(service: spy, userID: "u")

        #expect(spy.looseTrackRequests.isEmpty)
        #expect(vm.displayedError != nil)
    }

    /// If the fallback itself fails, the answer the server did give (zero albums) still stands, so
    /// the tab keeps the empty state rather than reporting the second request's failure as its own.
    @Test func aFailedFallbackLeavesTheEmptyStateStanding() async {
        let spy = MusicSpy()
        spy.looseTrackError = APIError.timeout

        let vm = MusicHomeViewModel()
        await vm.load(service: spy, userID: "u")

        #expect(vm.songs.isEmpty)
        #expect(vm.albums.isEmpty)
        #expect(vm.displayedError == nil)
    }

    /// Once the library is organised into folders and the albums arrive, the fallback list has to go,
    /// or the tab shows both answers at once.
    @Test func arrivingAlbumsClearTheTrackFallback() async throws {
        let spy = MusicSpy()
        spy.looseTracks = [try track("t1")]

        let vm = MusicHomeViewModel()
        await vm.load(service: spy, userID: "u")
        #expect(vm.songs.map(\.id) == ["t1"])

        spy.albums = [try album("a")]
        await vm.load(service: spy, userID: "u")

        #expect(vm.albums.map(\.id) == ["a"])
        #expect(vm.songs.isEmpty)
    }

    /// The track list is content like the grid is: a reload that fails behind it must not replace it
    /// with an error screen.
    @Test func aFailedReloadKeepsTheTrackListOnScreen() async throws {
        let spy = MusicSpy()
        spy.looseTracks = [try track("t1")]

        let vm = MusicHomeViewModel()
        await vm.load(service: spy, userID: "u")
        #expect(vm.songs.map(\.id) == ["t1"])

        spy.error = APIError.timeout
        await vm.load(service: spy, userID: "u")

        #expect(vm.songs.map(\.id) == ["t1"])
        #expect(vm.errorMessage != nil)
        #expect(vm.displayedError == nil)
    }

    /// The fallback asks per music library, typed and scoped, and it is capped: an unbounded `Audio`
    /// query against a large library is a page nobody can scroll.
    @Test func theTrackQueryIsScopedTypedAndCapped() {
        let query = JellyfinMusicService.allSongsQuery(libraryID: "lib", limit: 400)
        let items = query.toQueryItems()
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(value("ParentId") == "lib")
        #expect(value("IncludeItemTypes") == "Audio")
        #expect(value("Limit") == "400")
        #expect(value("Recursive") == "true")
        #expect(value("Fields") == JellyfinEndpoint.musicListFields)
    }
}
