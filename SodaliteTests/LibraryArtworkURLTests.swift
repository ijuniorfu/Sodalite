import Foundation
import Testing
@testable import Sodalite

/// Sodalite#84. The My Media tile paints the library's own artwork and only falls back to the
/// generic icon when the server has none, so what these pin is the fallback order: a library with
/// artwork must never resolve to nil, and a library without one must never resolve to a URL that
/// would 404 into an empty tile.
struct LibraryArtworkURLTests {
    private let service = JellyfinImageService(baseURLProvider: { URL(string: "https://jf.test") })

    private func library(primary: String? = nil, thumb: String? = nil) -> JellyfinLibrary {
        JellyfinLibrary(
            id: "lib1",
            name: "Movies",
            collectionType: "movies",
            imageTags: ImageTags(primary: primary, backdrop: nil, thumb: thumb, logo: nil, banner: nil)
        )
    }

    @Test("a library with a Primary image resolves to it")
    func primaryImage() throws {
        let url = try #require(service.libraryArtworkURL(for: library(primary: "p1")))
        #expect(url.path == "/Items/lib1/Images/Primary")
        #expect(url.query?.contains("tag=p1") == true)
        #expect(url.query?.contains("maxWidth=720") == true)
    }

    @Test("Primary wins over Thumb when the library carries both")
    func primaryBeatsThumb() throws {
        let url = try #require(service.libraryArtworkURL(for: library(primary: "p1", thumb: "t1")))
        #expect(url.path == "/Items/lib1/Images/Primary")
        #expect(url.query?.contains("tag=p1") == true)
    }

    @Test("a Thumb-only library falls back to Thumb rather than the generic tile")
    func thumbFallback() throws {
        let url = try #require(service.libraryArtworkURL(for: library(thumb: "t1")))
        #expect(url.path == "/Items/lib1/Images/Thumb")
        #expect(url.query?.contains("tag=t1") == true)
    }

    @Test("a library without artwork resolves to nil, which is what shows the generic tile")
    func noArtwork() {
        #expect(service.libraryArtworkURL(for: library()) == nil)
        #expect(service.libraryArtworkURL(
            for: JellyfinLibrary(id: "lib2", name: "Shows", collectionType: "tvshows", imageTags: nil)
        ) == nil)
    }
}
