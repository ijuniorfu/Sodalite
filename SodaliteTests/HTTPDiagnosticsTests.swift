import Testing
import Foundation
@testable import Sodalite

/// A failed request now says so once, at the `HTTPClient` funnel (Sodalite#88). The line is read by
/// someone else, in a language neither of us picked, so what carries the meaning has to be the
/// numbers and the key path rather than the localized sentence beside them.
struct HTTPDiagnosticsTests {

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(_ name: String) { stringValue = name; intValue = nil }
        init(index: Int) { stringValue = "Index \(index)"; intValue = index }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { self.init(index: intValue) }
    }

    private let url = URL(string: "https://media.example.com/Users/u1/Items?IncludeItemTypes=MusicAlbum&Recursive=true")!

    @Test func aStatusLineCarriesTheCodeAndTheServerText() {
        let line = HTTPDiagnostics.status(
            method: "GET",
            url: url,
            statusCode: 400,
            body: Data(#"{"message":"Fields is invalid"}"#.utf8)
        )

        #expect(line.hasPrefix("[http] GET "))
        #expect(line.contains("IncludeItemTypes=MusicAlbum"))
        #expect(line.contains("-> 400: Fields is invalid"))
    }

    @Test func aStatusLineWithoutABodyStillNamesTheCode() {
        let line = HTTPDiagnostics.status(method: "DELETE", url: url, statusCode: 503, body: nil)

        #expect(line.hasSuffix("-> 503"))
    }

    @Test func aTransportLineCarriesTheNumericURLErrorCode() {
        let line = HTTPDiagnostics.transport(
            method: "GET",
            url: url,
            error: URLError(.timedOut)
        )

        #expect(line.contains("transport: URLError -1001 timedOut"))
        // The name is English on every device: a screenshot of this log is read by someone who does
        // not share the reporter's locale.
        #expect(HTTPDiagnostics.describe(URLError(.callIsActive)) == "URLError -1019")
    }

    @Test func aDecodeLineNamesTheKeyPathIncludingArrayIndices() {
        let error = DecodingError.keyNotFound(
            Key("Name"),
            .init(codingPath: [Key("Items"), Key(index: 3)], debugDescription: "")
        )

        let line = HTTPDiagnostics.decode(method: "GET", url: url, type: JellyfinItemsResponse.self, error: error)

        #expect(line.contains("decode JellyfinItemsResponse: missing key Name at Items[3]"))
    }

    @Test func aFailureOnTheEnvelopeItselfReportsTheRoot() {
        let error = DecodingError.typeMismatch(
            Int.self,
            .init(codingPath: [], debugDescription: "")
        )

        #expect(HTTPDiagnostics.describe(error) == "expected Int at <root>")
    }

    @Test func aForeignErrorFallsBackToItsOwnDescription() {
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }

        #expect(HTTPDiagnostics.describe(Boom()) == "boom")
    }
}
