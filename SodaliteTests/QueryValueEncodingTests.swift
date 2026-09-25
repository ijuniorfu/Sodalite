import Foundation
import Testing
@testable import Sodalite

/// Audit 2026-09-25 NETWORK-1. Seerr's request validator answers 400 to a query value holding any
/// RFC 3986 reserved character, and `URLComponents` leaves the sub-delimiters literal, so a search for
/// "Grey's Anatomy" or a person page for "Lupita Nyong'o" quietly came back empty.
@Suite("Query values go out encoded against the unreserved set")
struct QueryValueEncodingTests {

    private struct Endpoint: APIEndpoint {
        let path = "Items"
        let method = HTTPMethod.get
        let items: [URLQueryItem]
        var queryItems: [URLQueryItem]? { items }
        var requiresAuth: Bool { false }
        var timeoutInterval: TimeInterval? { nil }
    }

    private func query(_ items: [URLQueryItem]) throws -> String {
        let request = try HTTPClient().buildRequest(
            baseURL: URL(string: "https://jf.example.com")!, endpoint: Endpoint(items: items), headers: [:])
        return try #require(request.url?.query(percentEncoded: true))
    }

    @Test("reserved characters in a value are escaped", arguments: [
        ("Fields", "a,b", "Fields=a%2Cb"),
        ("query", "Grey's", "query=Grey%27s"),
        ("query", "Mission: Impossible", "query=Mission%3A%20Impossible"),
        ("query", "Birdman (2014)", "query=Birdman%20%282014%29"),
        ("query", "Disney+", "query=Disney%2B"),
        ("query", "a&b=c#d", "query=a%26b%3Dc%23d"),
        ("query", "Amélie", "query=Am%C3%A9lie"),
        ("query", "WALL-E_1.0~", "query=WALL-E_1.0~"),
    ])
    func escapes(name: String, value: String, expected: String) throws {
        #expect(try query([URLQueryItem(name: name, value: value)]) == expected)
    }

    @Test("several items keep their order and separators")
    func severalItems() throws {
        #expect(try query([
            URLQueryItem(name: "query", value: "Lupita Nyong'o"),
            URLQueryItem(name: "page", value: "1"),
        ]) == "query=Lupita%20Nyong%27o&page=1")
    }

    @Test("an endpoint without query items gets no query")
    func noItems() {
        #expect(HTTPClient.percentEncoded(nil) == nil)
    }
}
