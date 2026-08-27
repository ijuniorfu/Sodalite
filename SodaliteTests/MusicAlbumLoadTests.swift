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
        var error: Error?
        private(set) var albumRequests: [String] = []
        private(set) var songRequests: [String] = []

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

        func hasMusicLibrary(userID: String) async throws -> Bool { true }
    }

    private func album(_ id: String) throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"Album \#(id)","Type":"MusicAlbum"}"#.utf8)
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
}
