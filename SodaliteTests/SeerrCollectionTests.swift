import Testing
import Foundation
@testable import Sodalite

/// The collection page reads a wire contract nothing else in the app touches: `/movie/{id}` carries the
/// `collection` stub that opens the page, and `/collection/{id}` carries the parts. Both are decoded straight into
/// existing model shapes, so a field rename on either side would surface as an empty page rather than a build error.
struct SeerrCollectionTests {
    /// The stub `/movie/{id}` returns for a movie that belongs to a collection; it alone drives the entry point.
    @Test func movieDetailCarriesTheCollectionStub() throws {
        let json = """
        {
          "id": 438148,
          "title": "Minions: The Rise of Gru",
          "collection": {
            "id": 86066,
            "name": "Despicable Me Collection",
            "posterPath": "/poster.jpg",
            "backdropPath": "/backdrop.jpg"
          }
        }
        """
        let detail = try decodeSeerr(SeerrMovieDetail.self, from: json)
        #expect(detail.collection?.id == 86066)
        #expect(detail.collection?.name == "Despicable Me Collection")
        #expect(detail.collection?.backdropPath == "/backdrop.jpg")
    }

    /// A standalone movie omits the key entirely; the entry point has to stay absent rather than fail the decode.
    @Test func movieWithoutACollectionDecodes() throws {
        let detail = try decodeSeerr(SeerrMovieDetail.self, from: #"{"id": 27205, "title": "Inception"}"#)
        #expect(detail.collection == nil)
    }

    /// Jellyseerr builds `parts` with its own `mapMovieResult`, so each entry carries `mediaType` and the same
    /// `mediaInfo` the discover rows use. That is what gives the cards their availability badge with no extra lookup.
    @Test func collectionPartsDecodeAsMediaWithAvailability() throws {
        let collection = try decodeSeerr(SeerrCollection.self, from: collectionJSON)
        #expect(collection.name == "Despicable Me Collection")
        #expect(collection.parts?.count == 3)
        #expect(collection.parts?.first?.mediaType == .movie)
        #expect(collection.parts?.first?.mediaInfo?.status == .available)
        #expect(collection.parts?.last?.mediaInfo == nil)
    }

    /// Requestable = nothing on the server and nothing in flight. Re-posting an available or already requested title
    /// only earns a 202 from Seerr, which would read as a failure in the bulk result.
    @Test func onlyUnservedPartsAreRequested() throws {
        let collection = try decodeSeerr(SeerrCollection.self, from: collectionJSON)
        let missing = SeerrCollectionRequestPlan.missingParts(in: collection.parts ?? [])
        #expect(missing.map(\.id) == [3])
    }

    /// A title pulled back out of Radarr comes back as DELETED (7) and has to stay re-requestable; treating it as
    /// served would leave the collection permanently un-completable from this page.
    @Test func deletedPartsStayRequestable() {
        let parts = [
            part(id: 1, status: 7),
            part(id: 2, status: 5),
            part(id: 3, status: 2),
            part(id: 4, status: 3),
            part(id: 5, status: 4),
            part(id: 6, status: 1),
            part(id: 7, status: nil),
        ]
        #expect(SeerrCollectionRequestPlan.missingParts(in: parts).map(\.id) == [1, 6, 7])
    }
}

// MARK: - Fixtures

/// Same decoder configuration SeerrClient uses; the payloads are TMDB-shaped, so the key strategy matters.
private func decodeSeerr<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(T.self, from: Data(json.utf8))
}

private func part(id: Int, status: Int?) -> SeerrMedia {
    let mediaInfo = status.map { "\"mediaInfo\": {\"id\": \(id), \"tmdbId\": \(id), \"status\": \($0)}," } ?? ""
    let json = "{\(mediaInfo) \"id\": \(id), \"mediaType\": \"movie\", \"title\": \"Part \(id)\"}"
    // Fixture, not a decode under test: a malformed literal here is a test bug, so failing loudly is correct.
    return try! decodeSeerr(SeerrMedia.self, from: json)
}

private let collectionJSON = """
{
  "id": 86066,
  "name": "Despicable Me Collection",
  "overview": "Gru and his Minions.",
  "posterPath": "/poster.jpg",
  "backdropPath": "/backdrop.jpg",
  "parts": [
    {
      "id": 1,
      "mediaType": "movie",
      "title": "Despicable Me",
      "releaseDate": "2010-07-08",
      "posterPath": "/1.jpg",
      "mediaInfo": { "id": 11, "tmdbId": 1, "status": 5, "jellyfinMediaId": "abc" }
    },
    {
      "id": 2,
      "mediaType": "movie",
      "title": "Despicable Me 2",
      "releaseDate": "2013-06-26",
      "posterPath": "/2.jpg",
      "mediaInfo": { "id": 12, "tmdbId": 2, "status": 3 }
    },
    {
      "id": 3,
      "mediaType": "movie",
      "title": "Despicable Me 4",
      "releaseDate": "2024-06-20",
      "posterPath": "/3.jpg"
    }
  ]
}
"""
