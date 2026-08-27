import Testing
import Foundation
@testable import Sodalite

/// The items envelope is lenient about its elements and used to be strict about its count, so a
/// response that arrived without `TotalRecordCount` threw away a perfectly readable list of items
/// over a number only paging reads (Sodalite#88).
struct JellyfinItemsResponseTests {

    private func decode(_ json: String) throws -> JellyfinItemsResponse {
        try JSONDecoder().decode(JellyfinItemsResponse.self, from: Data(json.utf8))
    }

    @Test func aResponseWithoutTotalRecordCountKeepsItsItems() throws {
        let response = try decode(#"{"Items":[{"Id":"a","Name":"A","Type":"MusicAlbum"}]}"#)

        #expect(response.items.map(\.id) == ["a"])
        #expect(response.totalRecordCount == 1)
    }

    @Test func aNullTotalRecordCountFallsBackToWhatArrived() throws {
        let response = try decode(
            #"{"Items":[{"Id":"a","Name":"A","Type":"MusicAlbum"},{"Id":"b","Name":"B","Type":"MusicAlbum"}],"TotalRecordCount":null}"#
        )

        #expect(response.totalRecordCount == 2)
    }

    /// The count keeps reporting what the server has even when the client could not read the items,
    /// which is the pair of numbers that tells a dropped decode apart from an empty library.
    @Test func malformedElementsAreDroppedAndTheServerCountSurvives() throws {
        let response = try decode(
            #"{"Items":[{"Id":"a","Name":"A","Type":"MusicAlbum"},{"Id":"b"}],"TotalRecordCount":2}"#
        )

        #expect(response.items.map(\.id) == ["a"])
        #expect(response.totalRecordCount == 2)
    }

    @Test func anAbsentItemsArrayIsAnEmptyResponse() throws {
        let response = try decode(#"{"TotalRecordCount":0}"#)

        #expect(response.items.isEmpty)
        #expect(response.totalRecordCount == 0)
    }
}
