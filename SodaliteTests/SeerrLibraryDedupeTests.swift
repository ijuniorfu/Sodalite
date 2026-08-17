import Testing
import Foundation
@testable import Sodalite

/// The catalog rows exist to show what the server does NOT have, so both nets are load-bearing: the wrong
/// status read would hide requestable titles (or advertise owned ones), and a key that ignores the media
/// type would let a movie suppress an unrelated series, since TMDB reuses its numeric ids per namespace.
struct SeerrLibraryDedupeTests {
    // MARK: - Availability net

    /// Status here is the MEDIA axis, where the same integers mean something else than on a request
    /// (see SeerrMediaStatus). 4 and 5 are the only two that say "the server has it".
    @Test func onlyAvailableAndPartiallyAvailableCountAsOnServer() {
        let media = [
            entry(id: 1, status: nil),   // never touched
            entry(id: 2, status: 1),     // unknown
            entry(id: 3, status: 2),     // pending
            entry(id: 4, status: 3),     // processing
            entry(id: 5, status: 4),     // partially available
            entry(id: 6, status: 5),     // available
            entry(id: 7, status: 7),     // deleted
        ]
        #expect(SeerrLibraryDedupe.droppingAvailable(media).map(\.id) == [1, 2, 3, 4, 7])
    }

    /// A requested title is not on the server yet, and its badge is what stops a second request; dropping
    /// it here would make the row look like the request never happened.
    @Test func requestedTitlesStayVisible() {
        #expect(SeerrLibraryDedupe.droppingAvailable([entry(id: 1, status: 2)]).count == 1)
        #expect(SeerrLibraryDedupe.droppingAvailable([entry(id: 1, status: 3)]).count == 1)
    }

    // MARK: - Key net

    @Test func matchingTmdbIdOfTheSameTypeIsRemoved() throws {
        let owned = [try libraryItem(name: "Arrival", year: 2016, type: "Movie", tmdbID: 329865)]
        let candidates = [entry(id: 329865, status: nil, type: "movie", title: "Arrival")]
        #expect(SeerrLibraryDedupe.removing(candidates, matching: owned).isEmpty)
    }

    /// TMDB numbers the movie and tv namespaces separately, so an owned movie must not suppress the series
    /// that happens to carry the same id.
    @Test func sameIdInTheOtherNamespaceSurvives() throws {
        let owned = [try libraryItem(name: "Arrival", year: 2016, type: "Movie", tmdbID: 1399)]
        let candidates = [entry(id: 1399, status: nil, type: "tv", title: "Game of Thrones")]
        #expect(SeerrLibraryDedupe.removing(candidates, matching: owned).map(\.id) == [1399])
    }

    /// Manual imports and old scanner runs carry no provider ids at all; without the title+year fallback the
    /// library row and the catalog row would show the same title side by side.
    @Test func titleAndYearCatchItemsWithoutProviderIds() throws {
        let owned = [try libraryItem(name: "Blade Runner 2049", year: 2017, type: "Movie", tmdbID: nil)]
        let candidates = [
            entry(id: 335984, status: nil, type: "movie", title: "Blade Runner 2049", year: "2017-10-04"),
            entry(id: 78, status: nil, type: "movie", title: "Blade Runner", year: "1982-06-25"),
        ]
        #expect(SeerrLibraryDedupe.removing(candidates, matching: owned).map(\.id) == [78])
    }

    /// Spacing is normalized on both sides, the year is not: a remake is a different title.
    @Test func sameTitleInAnotherYearSurvives() throws {
        let owned = [try libraryItem(name: "The  Thing", year: 1982, type: "Movie", tmdbID: nil)]
        let candidates = [
            entry(id: 1, status: nil, type: "movie", title: "the thing", year: "1982-06-25"),
            entry(id: 2, status: nil, type: "movie", title: "The Thing", year: "2011-10-14"),
        ]
        #expect(SeerrLibraryDedupe.removing(candidates, matching: owned).map(\.id) == [2])
    }

    /// Episodes, seasons and box sets have no Seerr counterpart, so they must contribute no keys at all
    /// rather than a key that could collide with a real title.
    @Test func nonMovieNonSeriesLibraryItemsContributeNoKeys() throws {
        let owned = [try libraryItem(name: "Arrival", year: 2016, type: "Episode", tmdbID: 329865)]
        let candidates = [entry(id: 329865, status: nil, type: "movie", title: "Arrival", year: "2016-11-10")]
        #expect(SeerrLibraryDedupe.removing(candidates, matching: owned).map(\.id) == [329865])
    }
}

// MARK: - Fixtures

/// Same decoder configuration SeerrClient uses; the payloads are TMDB-shaped, so the key strategy matters.
private func decodeSeerr<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(T.self, from: Data(json.utf8))
}

private func entry(
    id: Int,
    status: Int?,
    type: String = "movie",
    title: String = "Title",
    year: String? = nil
) -> SeerrMedia {
    let mediaInfo = status.map { "\"mediaInfo\": {\"id\": \(id), \"tmdbId\": \(id), \"status\": \($0)}," } ?? ""
    let release = year.map { "\"releaseDate\": \"\($0)\", \"firstAirDate\": \"\($0)\"," } ?? ""
    let name = type == "tv" ? "\"name\"" : "\"title\""
    let json = "{\(mediaInfo) \(release) \"id\": \(id), \"mediaType\": \"\(type)\", \(name): \"\(title)\"}"
    // Fixture, not a decode under test: a malformed literal here is a test bug, so failing loudly is correct.
    return try! decodeSeerr(SeerrMedia.self, from: json)
}

private func libraryItem(name: String, year: Int?, type: String, tmdbID: Int?) throws -> JellyfinItem {
    let providers = tmdbID.map { ",\"ProviderIds\":{\"Tmdb\":\"\($0)\"}" } ?? ""
    let production = year.map { ",\"ProductionYear\":\($0)" } ?? ""
    let json = "{\"Id\":\"\(name)\",\"Name\":\"\(name)\",\"Type\":\"\(type)\"\(production)\(providers)}"
    return try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
}
