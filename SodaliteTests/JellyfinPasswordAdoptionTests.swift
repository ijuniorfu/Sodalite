import Foundation
import Testing
@testable import Sodalite

/// The Seerr sign-in is the one screen that still asks for the Jellyfin password, so it keeps what
/// it is given. It is verified against Jellyfin first: Jellyseerr can authenticate against a
/// different Jellyfin instance, and an unverified password would only surface as a failed token
/// refresh plus a wrong-password attempt against the server.
@Suite("Adopting a Jellyfin password from the Seerr sign-in", .serialized)
@MainActor
struct JellyfinPasswordAdoptionTests {
    private let server = JellyfinServer(
        id: "server-1",
        name: "Home",
        internalURL: URL(string: "http://jellyfin.local:8096"),
        externalURL: nil
    )

    private func user(_ id: String, _ name: String) throws -> JellyfinUser {
        try JSONDecoder().decode(
            JellyfinUser.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(name)","ServerId":"server-1"}"#.utf8)
        )
    }

    private func authJSON(userID: String, name: String, token: String) -> Data {
        Data(#"""
        {"User":{"Id":"\#(userID)","Name":"\#(name)","ServerId":"server-1"},
         "AccessToken":"\#(token)","ServerId":"server-1"}
        """#.utf8)
    }

    /// Session in the shape a Quick Connect sign-in leaves behind: token, no password.
    private func passwordlessContainer(
        http: StubHTTPClient
    ) throws -> DependencyContainer {
        let container = DependencyContainer(keychainService: InMemoryKeychain(), httpClient: http)
        try container.saveSession(
            server: server,
            user: try user("user-a", "Vincent"),
            token: "old-token"
        )
        return container
    }

    @Test func aVerifiedPasswordIsKept() async throws {
        let http = StubHTTPClient()
        http.responses["/Users/AuthenticateByName"] = authJSON(
            userID: "user-a", name: "Vincent", token: "fresh-token"
        )
        let container = try passwordlessContainer(http: http)

        let adopted = await container.adoptJellyfinPassword(username: "Vincent", password: "hunter2")

        #expect(adopted)
        #expect(container.loadJellyfinPassword() == "hunter2")
    }

    /// Same username on a different Jellyfin behind Jellyseerr: the login succeeds but is not this
    /// profile, and writing it would break the very refresh path the password exists for.
    @Test func aPasswordForAnotherProfileIsRejected() async throws {
        let http = StubHTTPClient()
        http.responses["/Users/AuthenticateByName"] = authJSON(
            userID: "someone-else", name: "Vincent", token: "fresh-token"
        )
        let container = try passwordlessContainer(http: http)

        let adopted = await container.adoptJellyfinPassword(username: "Vincent", password: "hunter2")

        #expect(!adopted)
        #expect(container.loadJellyfinPassword() == nil)
    }

    @Test func aRejectedLoginWritesNothing() async throws {
        let http = StubHTTPClient()
        let container = try passwordlessContainer(http: http)

        let adopted = await container.adoptJellyfinPassword(username: "Vincent", password: "wrong")

        #expect(!adopted)
        #expect(container.loadJellyfinPassword() == nil)
    }

    /// Nothing to adopt means nothing to ask Jellyfin about.
    @Test func anAlreadyCachedPasswordCostsNoRoundTrip() async throws {
        let http = StubHTTPClient()
        let container = DependencyContainer(keychainService: InMemoryKeychain(), httpClient: http)
        try container.saveSession(
            server: server,
            user: try user("user-a", "Vincent"),
            token: "old-token",
            password: "hunter2"
        )
        http.requestedPaths.removeAll()

        let adopted = await container.adoptJellyfinPassword(username: "Vincent", password: "other")

        #expect(!adopted)
        #expect(http.requestedPaths.isEmpty)
        #expect(container.loadJellyfinPassword() == "hunter2")
    }

    @Test func anEmptyPasswordIsIgnored() async throws {
        let http = StubHTTPClient()
        let container = try passwordlessContainer(http: http)

        let adopted = await container.adoptJellyfinPassword(username: "Vincent", password: "")

        #expect(!adopted)
        #expect(http.requestedPaths.isEmpty)
    }

    final class StubHTTPClient: HTTPClientProtocol, @unchecked Sendable {
        var responses: [String: Data] = [:]
        var requestedPaths: [String] = []

        func request<T: Decodable>(
            baseURL: URL,
            endpoint: APIEndpoint,
            headers: [String: String],
            responseType: T.Type
        ) async throws -> T {
            requestedPaths.append(endpoint.path)
            guard let data = responses[endpoint.path] else { throw APIError.unauthorized(message: nil) }
            return try JSONDecoder().decode(T.self, from: data)
        }

        func request(baseURL: URL, endpoint: APIEndpoint, headers: [String: String]) async throws {
            requestedPaths.append(endpoint.path)
        }

        func requestData(
            baseURL: URL,
            endpoint: APIEndpoint,
            headers: [String: String]
        ) async throws -> (Data, HTTPURLResponse) {
            requestedPaths.append(endpoint.path)
            throw APIError.unauthorized(message: nil)
        }
    }
}
