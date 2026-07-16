import Testing
import Foundation
@testable import Sodalite

/// Jellyseerr's POST /request answers some failures with 2xx + an error JSON instead of a request object
/// (202 NoSeasonsAvailableError being the known case), so createRequest must surface those instead of
/// dying in the SeerrRequest decode with a generic "could not process server response".
@MainActor
struct SeerrRequestServiceTests {
    private final class StubHTTPClient: HTTPClientProtocol, @unchecked Sendable {
        let statusCode: Int
        let body: String

        init(statusCode: Int, body: String) {
            self.statusCode = statusCode
            self.body = body
        }

        func requestData(
            baseURL: URL,
            endpoint: APIEndpoint,
            headers: [String: String]
        ) async throws -> (Data, HTTPURLResponse) {
            let response = HTTPURLResponse(
                url: baseURL,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(body.utf8), response)
        }

        func request<T: Decodable>(
            baseURL: URL,
            endpoint: APIEndpoint,
            headers: [String: String],
            responseType: T.Type
        ) async throws -> T {
            let (data, _) = try await requestData(baseURL: baseURL, endpoint: endpoint, headers: headers)
            return try JSONDecoder().decode(T.self, from: data)
        }

        func request(
            baseURL: URL,
            endpoint: APIEndpoint,
            headers: [String: String]
        ) async throws {}
    }

    private func makeService(statusCode: Int, body: String) -> SeerrRequestService {
        let client = SeerrClient(httpClient: StubHTTPClient(statusCode: statusCode, body: body))
        client.baseURL = URL(string: "https://seerr.example")
        return SeerrRequestService(client: client)
    }

    @Test func status202SurfacesNoSeasonsAvailable() async {
        let service = makeService(
            statusCode: 202,
            body: #"{"status":202,"message":"No seasons available to request"}"#
        )
        await #expect(throws: SeerrRequestError.noSeasonsAvailable) {
            try await service.createRequest(mediaType: .tv, tmdbID: 42, seasons: [1])
        }
    }

    @Test func undecodable2xxBodySurfacesServerMessage() async {
        let service = makeService(
            statusCode: 200,
            body: #"{"status":500,"message":"Something went wrong"}"#
        )
        await #expect(throws: SeerrRequestError.serverRejected(message: "Something went wrong")) {
            try await service.createRequest(mediaType: .tv, tmdbID: 42, seasons: [1])
        }
    }

    @Test func undecodable2xxBodyWithoutMessageKeepsDecodingError() async {
        let service = makeService(statusCode: 200, body: #"{"unexpected":true}"#)
        do {
            _ = try await service.createRequest(mediaType: .tv, tmdbID: 42, seasons: [1])
            Issue.record("Expected createRequest to throw")
        } catch is SeerrRequestError {
            Issue.record("Expected the original decoding error, got SeerrRequestError")
        } catch {
            // APIError.decodingError expected; anything non-SeerrRequestError is the preserved original.
        }
    }

    @Test func createdRequestStillDecodes() async throws {
        let service = makeService(
            statusCode: 201,
            body: #"{"id":7,"status":1,"type":"tv","seasons":[{"id":1,"seasonNumber":1,"status":2}]}"#
        )
        let request = try await service.createRequest(mediaType: .tv, tmdbID: 42, seasons: [1])
        #expect(request.id == 7)
        #expect(request.seasons?.first?.seasonNumber == 1)
    }
}
