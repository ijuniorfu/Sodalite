import Testing
import Foundation
@testable import Sodalite

/// The lenient Seerr enum decoders exist so an unknown server value falls back instead of aborting the whole array decode.
@MainActor
struct SeerrDecodingTests {
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    /// 7 is the server's DELETED and must survive the decode; 6 (blocklisted) has no UI and stays unknown.
    @Test func mediaStatusMapsKnownAndFallsBackUnknown() throws {
        let values = try decode([SeerrMediaStatus].self, "[5, 2, 6, 7, 1000]")
        #expect(values == [.available, .pending, .unknown, .deleted, .unknown])
    }

    @Test func mediaStatusOneBadElementDoesNotAbortArray() throws {
        let values = try decode([SeerrMediaStatus].self, "[2, 99]")
        #expect(values == [.pending, .unknown])
    }

    @Test func requestStatusFallsBackToPendingApproval() throws {
        let values = try decode([SeerrRequestStatus].self, "[5, 99]")
        #expect(values == [.completed, .pendingApproval])
    }

    @Test func mediaTypeFallsBackToUnknown() throws {
        let values = try decode([SeerrMediaType].self, "[\"movie\", \"tv\", \"person\", \"wibble\"]")
        #expect(values == [.movie, .tv, .person, .unknown])
    }
}
