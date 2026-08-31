import Foundation
import Testing
@testable import Sodalite

/// Sodalite#90, second round. The reconcile held every remembered profile against the server's own
/// user table but abstained wherever that table did not carry the session's own user, which is
/// exactly the signature of "the active profile was the user that got deleted". The card therefore
/// survived every pass until the user switched to another profile, and only then disappeared.
///
/// The ambiguity (my user is gone / this table is not mine) has one source of evidence: whether the
/// token still resolves. So the reconcile asks it instead of abstaining.
@Suite("Reconciling when the deleted user is the active profile", .serialized)
@MainActor
struct DeletedActiveProfileReconcileTests {
    private let server = JellyfinServer(
        id: "srv-90b", name: "Home", internalURL: URL(string: "http://10.0.0.2:8096"), externalURL: nil
    )

    private func user(_ id: String, _ name: String) throws -> JellyfinUser {
        try JSONDecoder().decode(
            JellyfinUser.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(name)","ServerId":"srv-90b"}"#.utf8)
        )
    }

    private func userTable(_ ids: [String]) -> Data {
        let entries = ids.map { #"{"Id":"\#($0)","Name":"Name \#($0)","ServerId":"srv-90b"}"# }
        return Data("[\(entries.joined(separator: ","))]".utf8)
    }

    /// Signed in as `user-a`, with the other ids remembered beside it.
    private func session(
        http: StubHTTPClient,
        alsoRemembered others: [String] = []
    ) throws -> DependencyContainer {
        let container = DependencyContainer(keychainService: InMemoryKeychain(), httpClient: http)
        try container.saveSession(
            server: server,
            user: try user("user-a", "Vincent"),
            token: "token-a",
            password: "hunter2"
        )
        for id in others {
            try container.rememberUser(
                RememberedUser(id: id, serverID: server.id, name: "Name \(id)", imageTag: nil, token: "t-\(id)")
            )
        }
        return container
    }

    private func rememberedIDs(_ container: DependencyContainer) -> [String] {
        container.listRememberedUsers(serverID: server.id).map(\.id).sorted()
    }

    /// The reported case: the server still answers, its table simply no longer lists the profile
    /// this session is signed in as.
    @Test func theActiveProfileGoesWhenTheServerNoLongerHasIt() async throws {
        let http = StubHTTPClient()
        http.responses["/Users"] = userTable(["user-b"])
        let container = try session(http: http, alsoRemembered: ["user-b"])
        let appState = AppState()
        container.appState = appState

        await container.reconcileRememberedProfiles()

        #expect(rememberedIDs(container) == ["user-b"])
        #expect(appState.rejectedProfileName == "Vincent")
        #expect(container.jellyfinClient.accessToken == nil)
    }

    /// Deleting a user takes its tokens with it, so the table itself can come back refused. That
    /// refusal is an answer about this session, not a reason to give up on the pass.
    @Test func aRefusedUserTableEndsTheSessionItWasAskedWith() async throws {
        let http = StubHTTPClient()
        let container = try session(http: http, alsoRemembered: ["user-b"])
        let appState = AppState()
        container.appState = appState

        await container.reconcileRememberedProfiles()

        #expect(rememberedIDs(container) == ["user-b"])
        #expect(appState.rejectedProfileName == "Vincent")
    }

    /// The other stale cards go in the same pass: once the session is over, nothing speaks for them
    /// either, and the table is still the server's own answer.
    @Test func theOtherStaleProfilesGoInTheSamePass() async throws {
        let http = StubHTTPClient()
        http.responses["/Users"] = userTable(["user-c"])
        let container = try session(http: http, alsoRemembered: ["user-b", "user-c"])

        await container.reconcileRememberedProfiles()

        #expect(rememberedIDs(container) == ["user-c"])
    }

    /// The rule the abstention was written for still holds: a token that resolves against a table
    /// that does not list it describes two different servers, and neither profile may be dropped
    /// on that. Same shape as the deletion, told apart by /Users/Me.
    @Test func aTableWithoutTheSessionsUserDecidesNothingWhileTheTokenResolves() async throws {
        let http = StubHTTPClient()
        http.responses["/Users"] = userTable(["user-x", "user-y"])
        http.responses["/Users/Me"] = Data(#"{"Id":"user-a","Name":"Vincent","ServerId":"srv-90b"}"#.utf8)
        let container = try session(http: http, alsoRemembered: ["user-b"])

        await container.reconcileRememberedProfiles()

        #expect(rememberedIDs(container) == ["user-a", "user-b"])
        #expect(container.jellyfinClient.accessToken == "token-a")
    }

    /// A refused token that a stored password can replace is an expired token, not a deleted user.
    @Test func aTokenTheStoredPasswordCanReplaceKeepsTheProfile() async throws {
        let http = StubHTTPClient()
        http.responses["/Users/AuthenticateByName"] = Data(#"""
        {"User":{"Id":"user-a","Name":"Vincent","ServerId":"srv-90b"},
         "AccessToken":"fresh-token","ServerId":"srv-90b"}
        """#.utf8)
        let container = try session(http: http, alsoRemembered: ["user-b"])

        await container.reconcileRememberedProfiles()

        #expect(rememberedIDs(container) == ["user-a", "user-b"])
        #expect(container.jellyfinClient.accessToken == "fresh-token")
    }

    /// A server that cannot be reached has told this device nothing about who it still has.
    @Test func anUnreachableServerChangesNothing() async throws {
        let http = StubHTTPClient()
        http.error = URLError(.notConnectedToInternet)
        let container = try session(http: http, alsoRemembered: ["user-b"])
        let appState = AppState()
        container.appState = appState

        await container.reconcileRememberedProfiles()

        #expect(rememberedIDs(container) == ["user-a", "user-b"])
        #expect(appState.rejectedProfileName == nil)
    }

    /// Paths without a canned response answer 401, which is what a deleted user's token gets.
    final class StubHTTPClient: HTTPClientProtocol, @unchecked Sendable {
        var responses: [String: Data] = [:]
        /// Thrown for every path when set, so a transport failure can be told from a refusal.
        var error: (any Error)?

        func request<T: Decodable>(
            baseURL: URL,
            endpoint: APIEndpoint,
            headers: [String: String],
            responseType: T.Type
        ) async throws -> T {
            if let error { throw error }
            guard let data = responses[endpoint.path] else { throw APIError.unauthorized(message: nil) }
            return try JSONDecoder().decode(T.self, from: data)
        }

        func request(baseURL: URL, endpoint: APIEndpoint, headers: [String: String]) async throws {
            if let error { throw error }
        }

        func requestData(
            baseURL: URL,
            endpoint: APIEndpoint,
            headers: [String: String]
        ) async throws -> (Data, HTTPURLResponse) {
            throw error ?? APIError.unauthorized(message: nil)
        }
    }
}
