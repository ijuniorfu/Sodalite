import Foundation

protocol JellyfinAuthServiceProtocol: Sendable {
    func login(username: String, password: String) async throws -> JellyfinAuthResponse
    func initiateQuickConnect() async throws -> QuickConnectInitResponse
    func checkQuickConnect(secret: String) async throws -> Bool
    func authenticateWithQuickConnect(secret: String) async throws -> JellyfinAuthResponse
    func getPublicUsers() async throws -> [JellyfinUser]
    func getCurrentUser() async throws -> JellyfinUser
}

final class JellyfinAuthService: JellyfinAuthServiceProtocol {
    private let client: JellyfinClient

    init(client: JellyfinClient) {
        self.client = client
    }

    func login(username: String, password: String) async throws -> JellyfinAuthResponse {
        try await client.request(
            endpoint: JellyfinEndpoint.authenticateByName(username: username, password: password),
            responseType: JellyfinAuthResponse.self
        )
    }

    func initiateQuickConnect() async throws -> QuickConnectInitResponse {
        try await client.request(
            endpoint: JellyfinEndpoint.quickConnectInitiate,
            responseType: QuickConnectInitResponse.self
        )
    }

    func checkQuickConnect(secret: String) async throws -> Bool {
        let response = try await client.request(
            endpoint: JellyfinEndpoint.quickConnectCheck(secret: secret),
            responseType: QuickConnectCheckResponse.self
        )
        return response.authenticated
    }

    func authenticateWithQuickConnect(secret: String) async throws -> JellyfinAuthResponse {
        try await client.request(
            endpoint: JellyfinEndpoint.quickConnectAuthenticate(secret: secret),
            responseType: JellyfinAuthResponse.self
        )
    }

    /// Login-screen user list; empty when "Show users on login screen" is off (or pre-10.x), callers fall back to a manual username field.
    func getPublicUsers() async throws -> [JellyfinUser] {
        try await client.request(
            endpoint: JellyfinEndpoint.publicUsers,
            responseType: [JellyfinUser].self
        )
    }

    /// /Users/Me, preferred over /Users/{id} because it needs no admin permission, resolves to whoever the token represents.
    func getCurrentUser() async throws -> JellyfinUser {
        try await client.request(
            endpoint: JellyfinEndpoint.currentUser,
            responseType: JellyfinUser.self
        )
    }
}
