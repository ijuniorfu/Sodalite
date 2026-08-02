import Testing
import Foundation
@testable import Sodalite

/// The person page has two independent halves. It must stay useful when either one is missing:
/// without Seerr it falls back to Jellyfin's own person item plus the library rows, and a Seerr
/// outage must never cost the rows (Sodalite#57).
@MainActor
struct PersonDetailViewModelTests {
    private func makeViewModel(
        items: PersonLibraryTests.ItemsSpy,
        media: MediaSpy = MediaSpy(),
        seerrConnected: Bool = true,
        userID: String? = "u"
    ) -> PersonDetailViewModel {
        PersonDetailViewModel(
            itemService: items,
            mediaService: media,
            isSeerrConnected: seerrConnected,
            userID: userID
        )
    }

    private func item(_ id: String, name: String, type: String, overview: String? = nil) throws -> JellyfinItem {
        let extra = overview.map { #","Overview":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(name)","Type":"\#(type)"\#(extra)}"#.utf8)
        )
    }

    @Test func withoutSeerrTheProfileComesFromJellyfin() async throws {
        let spy = PersonLibraryTests.ItemsSpy()
        spy.details = ["p1": try item("p1", name: "Mindy Kaling", type: "Person", overview: "An actress.")]
        spy.itemsByType = [.movie: [try item("m1", name: "Late Night", type: "Movie")]]

        let vm = makeViewModel(items: spy, seerrConnected: false)
        await vm.load(tmdbID: nil, jellyfinPersonID: "p1", name: "Mindy Kaling")

        #expect(vm.profile?.name == "Mindy Kaling")
        #expect(vm.profile?.biography == "An actress.")
        #expect(vm.profile?.jellyfinPersonID == "p1")
        #expect(vm.library.movies.map(\.id) == ["m1"])
        #expect(vm.errorMessage == nil)
        // No Seerr means no filmography to report as empty.
        #expect(vm.filmographyUnavailable)
        #expect(vm.filmography.isEmpty)
    }

    /// Nothing from either side is the only case that still deserves the error screen.
    @Test func withoutSeerrAndWithoutAnyJellyfinDataTheErrorRemains() async throws {
        let spy = PersonLibraryTests.ItemsSpy()

        let vm = makeViewModel(items: spy, seerrConnected: false)
        await vm.load(tmdbID: nil, jellyfinPersonID: "missing", name: "Nobody")

        #expect(vm.profile == nil)
        #expect(vm.library.isEmpty)
        #expect(vm.errorMessage != nil)
    }

    @Test func aSeerrOutageStillLeavesTheLibraryRows() async throws {
        let spy = PersonLibraryTests.ItemsSpy()
        spy.details = ["p1": try item("p1", name: "Mindy Kaling", type: "Person")]
        spy.itemsByType = [.episode: [try item("e1", name: "Pilot", type: "Episode")]]
        let media = MediaSpy()
        media.throwOnPerson = true

        let vm = makeViewModel(items: spy, media: media)
        await vm.load(tmdbID: 55638, jellyfinPersonID: "p1", name: "Mindy Kaling")

        #expect(vm.library.episodes.map(\.id) == ["e1"])
        #expect(vm.errorMessage == nil)
        #expect(vm.profile?.jellyfinPersonID == "p1")
    }

    @Test func withSeerrTheProfileAndFilmographyComeFromTMDB() async throws {
        let spy = PersonLibraryTests.ItemsSpy()
        spy.itemsByType = [.movie: [try item("m1", name: "Late Night", type: "Movie")]]
        spy.persons = [try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"p1","Name":"Mindy Kaling","Type":"Person","ProviderIds":{"Tmdb":"55638"}}"#.utf8)
        )]
        let media = MediaSpy()
        media.detail = try JSONDecoder().decode(
            SeerrPersonDetail.self,
            from: Data(#"{"id":55638,"name":"Mindy Kaling","biography":"From TMDB","profilePath":"/mk.jpg"}"#.utf8)
        )
        media.credits = try JSONDecoder().decode(
            SeerrPersonCredits.self,
            from: Data(#"{"cast":[{"id":1,"mediaType":"movie","title":"Late Night","posterPath":"/a.jpg"}]}"#.utf8)
        )

        let vm = makeViewModel(items: spy, media: media)
        await vm.load(tmdbID: 55638, jellyfinPersonID: nil, name: "Mindy Kaling")

        #expect(vm.profile?.biography == "From TMDB")
        #expect(vm.profile?.tmdbProfilePath == "/mk.jpg")
        #expect(vm.filmography.map(\.id) == [1])
        #expect(!vm.filmographyUnavailable)
        // The page came from Seerr, so the library rows had to resolve the person by name.
        #expect(vm.library.movies.map(\.id) == ["m1"])
    }

    /// Credits are decoration; losing them must not lose the profile that did load.
    @Test func failedCreditsKeepTheProfile() async throws {
        let spy = PersonLibraryTests.ItemsSpy()
        let media = MediaSpy()
        media.detail = try JSONDecoder().decode(
            SeerrPersonDetail.self,
            from: Data(#"{"id":55638,"name":"Mindy Kaling"}"#.utf8)
        )
        media.throwOnCredits = true

        let vm = makeViewModel(items: spy, media: media)
        await vm.load(tmdbID: 55638, jellyfinPersonID: nil, name: "Mindy Kaling")

        #expect(vm.profile?.name == "Mindy Kaling")
        #expect(vm.filmography.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    @Test func filmographyDedupesCastAndCrewAndDropsPosterlessCredits() throws {
        let credits = try JSONDecoder().decode(
            SeerrPersonCredits.self,
            from: Data(#"""
            {"cast":[{"id":1,"mediaType":"movie","title":"B","posterPath":"/b.jpg","releaseDate":"2019-01-01"},
                     {"id":2,"mediaType":"movie","title":"No Poster"}],
             "crew":[{"id":1,"mediaType":"movie","title":"B","posterPath":"/b.jpg","releaseDate":"2019-01-01"},
                     {"id":1,"mediaType":"tv","name":"A","posterPath":"/a.jpg","firstAirDate":"2021-01-01"}]}
            """#.utf8)
        )

        let result = PersonDetailViewModel.computeFilmography(from: credits)

        // Same numeric id across types stays two entries; newest first; the posterless one is gone.
        #expect(result.map(\.stableKey) == ["tv-1", "movie-1"])
    }

    final class MediaSpy: SeerrMediaServiceProtocol, @unchecked Sendable {
        var detail: SeerrPersonDetail?
        var credits: SeerrPersonCredits?
        var throwOnPerson = false
        var throwOnCredits = false

        func movieDetail(tmdbID: Int) async throws -> SeerrMovieDetail { throw Boom() }
        func tvDetail(tmdbID: Int) async throws -> SeerrTVDetail { throw Boom() }
        func tvSeasonDetail(tmdbID: Int, seasonNumber: Int) async throws -> SeerrSeasonDetail { throw Boom() }
        func collection(collectionID: Int) async throws -> SeerrCollection { throw Boom() }
        func recommendations(mediaType: SeerrMediaType, tmdbID: Int) async throws -> [SeerrMedia] { [] }
        func similar(mediaType: SeerrMediaType, tmdbID: Int) async throws -> [SeerrMedia] { [] }
        func ratings(mediaType: SeerrMediaType, tmdbID: Int) async throws -> SeerrRTRating { throw Boom() }
        func personDetail(tmdbID: Int) async throws -> SeerrPersonDetail {
            if throwOnPerson { throw Boom() }
            guard let detail else { throw Boom() }
            return detail
        }
        func personCredits(tmdbID: Int) async throws -> SeerrPersonCredits {
            if throwOnCredits || throwOnPerson { throw Boom() }
            guard let credits else { throw Boom() }
            return credits
        }
        func removeMovieFromRadarr(tmdbID: Int) async throws -> Bool { false }
        func removeSeriesFromSonarr(tmdbID: Int) async throws -> Bool { false }

        private struct Boom: Error {}
    }
}
