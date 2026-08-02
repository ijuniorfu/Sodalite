import Foundation

protocol SeerrSearchServiceProtocol: Sendable {
    func search(query: String, page: Int) async throws -> SeerrSearchResults
}

@MainActor
final class SeerrSearchService: SeerrSearchServiceProtocol {
    private let client: SeerrClient

    init(client: SeerrClient) {
        self.client = client
    }

    /// `SeerrSearchResults` sorts the mixed `results` array into requestable media and people;
    /// entries with no Sodalite destination (collections, unknown types) drop out during the decode.
    func search(query: String, page: Int = 1) async throws -> SeerrSearchResults {
        try await client.request(
            endpoint: SeerrEndpoint.search(query: query, page: page),
            responseType: SeerrSearchResults.self
        )
    }
}
