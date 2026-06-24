import Testing
import Foundation
@testable import Sodalite

/// Display fallbacks and the mediaType-prefixed stable key that prevents movie/tv TMDB-id collisions in ForEach/merging.
@MainActor
struct SeerrMediaTests {
    private func media(
        id: Int = 1,
        mediaType: SeerrMediaType = .movie,
        title: String? = nil,
        name: String? = nil,
        originalTitle: String? = nil,
        originalName: String? = nil,
        releaseDate: String? = nil,
        firstAirDate: String? = nil
    ) -> SeerrMedia {
        SeerrMedia(
            id: id, mediaType: mediaType,
            title: title, name: name,
            originalTitle: originalTitle, originalName: originalName,
            overview: nil, posterPath: nil, backdropPath: nil,
            releaseDate: releaseDate, firstAirDate: firstAirDate,
            voteAverage: nil, mediaInfo: nil
        )
    }

    @Test func displayTitleFollowsFallbackChain() {
        #expect(media(title: "T", name: "N").displayTitle == "T")
        #expect(media(name: "N").displayTitle == "N")
        #expect(media(originalTitle: "OT").displayTitle == "OT")
        #expect(media(originalName: "ON").displayTitle == "ON")
        #expect(media().displayTitle == "")
    }

    @Test func displayYearPrefersReleaseDateThenFirstAir() {
        #expect(media(releaseDate: "2021-05-04").displayYear == "2021")
        #expect(media(firstAirDate: "2019-01-01").displayYear == "2019")
        #expect(media(releaseDate: "2021-05-04", firstAirDate: "2019-01-01").displayYear == "2021")
    }

    @Test func displayYearIsNilForShortOrMissingDates() {
        #expect(media(releaseDate: "20").displayYear == nil)
        #expect(media().displayYear == nil)
    }

    @Test func stableKeyPrefixesMediaTypeToAvoidCollisions() {
        #expect(media(id: 603, mediaType: .movie).stableKey == "movie-603")
        #expect(media(id: 603, mediaType: .tv).stableKey == "tv-603")
        #expect(media(id: 603, mediaType: .movie).stableKey != media(id: 603, mediaType: .tv).stableKey)
    }
}
