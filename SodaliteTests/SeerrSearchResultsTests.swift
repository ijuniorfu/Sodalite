import Testing
import Foundation
@testable import Sodalite

/// `/api/v1/search` returns movies, series, people and collections in one `results` array, so the
/// response type has to sort them apart and survive an entry it cannot use (Sodalite#56).
@MainActor
struct SeerrSearchResultsTests {
    private let decoder: JSONDecoder = {
        // Mirrors SeerrClient; without it profilePath / knownFor would decode from the wrong keys.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func decode(_ json: String) throws -> SeerrSearchResults {
        try decoder.decode(SeerrSearchResults.self, from: Data(json.utf8))
    }

    private func envelope(_ results: String) -> String {
        """
        {"page": 1, "totalPages": 3, "totalResults": 42, "results": \(results)}
        """
    }

    @Test func mixedResultsSplitByMediaType() throws {
        let response = try decode(envelope("""
        [
          {"id": 1, "mediaType": "movie", "title": "Late Night"},
          {"id": 2, "mediaType": "person", "name": "Mindy Kaling"},
          {"id": 3, "mediaType": "tv", "name": "The Office"}
        ]
        """))

        #expect(response.media.map(\.id) == [1, 3])
        #expect(response.media.map(\.mediaType) == [.movie, .tv])
        #expect(response.people.map(\.name) == ["Mindy Kaling"])
    }

    @Test func pagingMetadataSurvives() throws {
        let response = try decode(envelope("[]"))

        #expect(response.page == 1)
        #expect(response.totalPages == 3)
        #expect(response.totalResults == 42)
    }

    @Test func personKeepsProfilePath() throws {
        let response = try decode(envelope("""
        [{"id": 2, "mediaType": "person", "name": "Mindy Kaling", "profilePath": "/abc.jpg"}]
        """))

        #expect(response.people.first?.profilePath == "/abc.jpg")
    }

    @Test func knownForSummaryJoinsTheFirstTwoTitles() throws {
        let response = try decode(envelope("""
        [{"id": 2, "mediaType": "person", "name": "Mindy Kaling", "knownFor": [
          {"id": 10, "mediaType": "tv", "name": "The Office"},
          {"id": 11, "mediaType": "movie", "title": "Ocean's Eight"},
          {"id": 12, "mediaType": "movie", "title": "Inside Out"}
        ]}]
        """))

        #expect(response.people.first?.knownForSummary == "The Office, Ocean's Eight")
    }

    @Test func personWithoutCreditsHasNoSummary() throws {
        let response = try decode(envelope("""
        [{"id": 2, "mediaType": "person", "name": "Mindy Kaling"}]
        """))

        #expect(response.people.first?.knownForSummary == nil)
    }

    /// A credit with neither title nor name would otherwise contribute an empty segment ", ".
    @Test func untitledCreditsAreSkippedInTheSummary() throws {
        let response = try decode(envelope("""
        [{"id": 2, "mediaType": "person", "name": "Mindy Kaling", "knownFor": [
          {"id": 10, "mediaType": "movie"},
          {"id": 11, "mediaType": "movie", "title": "Ocean's Eight"}
        ]}]
        """))

        #expect(response.people.first?.knownForSummary == "Ocean's Eight")
    }

    /// Collections are searchable in Jellyseerr but have no Sodalite destination, so they drop out
    /// of both lists rather than landing in the catalog row as an unopenable card.
    @Test func collectionEntriesAreDropped() throws {
        let response = try decode(envelope("""
        [
          {"id": 4, "mediaType": "collection", "name": "The Godfather Collection"},
          {"id": 1, "mediaType": "movie", "title": "Late Night"}
        ]
        """))

        #expect(response.media.map(\.id) == [1])
        #expect(response.people.isEmpty)
    }

    /// The whole search must not fail because one entry is malformed; the person here has no name.
    @Test func malformedEntryDoesNotAbortTheSearch() throws {
        let response = try decode(envelope("""
        [
          {"id": 2, "mediaType": "person"},
          {"id": 3, "mediaType": "person", "name": "Mindy Kaling"},
          {"id": 1, "mediaType": "movie", "title": "Late Night"}
        ]
        """))

        #expect(response.people.map(\.name) == ["Mindy Kaling"])
        #expect(response.media.map(\.id) == [1])
    }

    /// Credits are decoration under the name; a broken one costs the summary, not the person.
    @Test func malformedCreditDoesNotDropThePerson() throws {
        let response = try decode(envelope("""
        [{"id": 2, "mediaType": "person", "name": "Mindy Kaling", "knownFor": [
          {"mediaType": "movie", "title": "Missing Its Id"}
        ]}]
        """))

        #expect(response.people.map(\.name) == ["Mindy Kaling"])
        #expect(response.people.first?.knownForSummary == nil)
    }

    @Test func missingResultsKeyDecodesToEmptyLists() throws {
        let response = try decoder.decode(
            SeerrSearchResults.self,
            from: Data(#"{"page": 1, "totalPages": 1, "totalResults": 0}"#.utf8)
        )

        #expect(response.media.isEmpty)
        #expect(response.people.isEmpty)
    }
}
