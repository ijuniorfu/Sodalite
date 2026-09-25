import Foundation
import Testing
@testable import Sodalite

/// Signing in runs before there is an active server, and route resolution only ever covered the
/// active one. So the whole sign-in flow ran on `preferredURL(for:)`: the last route that worked,
/// else the internal slot. Somebody whose last session was at home therefore signed in against a
/// LAN address from a phone on cellular, and the symptom is that signing in works at home and
/// nowhere else, while the very same server answers fine in a browser.
@Suite("Signing in probes both addresses", .serialized)
@MainActor
struct ServerSignInRouteTests {
    private let serverID = "srv-signin"
    private let internalURL = URL(string: "http://10.0.0.2:8096")!
    private let externalURL = URL(string: "https://jf.example.com")!

    private func container(answering reachable: Set<URL>) throws -> DependencyContainer {
        let container = DependencyContainer(
            keychainService: InMemoryKeychain(),
            defaults: UserDefaults(suiteName: "signin-route-\(UUID().uuidString)")!
        )
        try container.addServer(JellyfinServer(
            id: serverID, name: "Home", internalURL: internalURL, externalURL: externalURL
        ))
        container.jellyfinProbe = { url, _ in reachable.contains(url) }
        return container
    }

    /// The reporter's case: last session was at home, this one is on cellular.
    @Test func awayFromHomeTheExternalAddressWins() async throws {
        let container = try container(answering: [externalURL])
        container.serverRouteStore.setLastRoute(.internal, serverID: serverID)
        let server = try #require(container.listKnownServers().first)

        let client = container.makeSignInClient(for: server)
        let resolved = await container.resolveSignInRoute(for: server, client: client)

        #expect(resolved == externalURL)
        #expect(client.baseURL == externalURL)
    }

    /// At home the LAN address still wins, so the fix does not push every sign-in through the proxy.
    @Test func atHomeTheInternalAddressStillWins() async throws {
        let container = try container(answering: [internalURL, externalURL])
        container.serverRouteStore.setLastRoute(.external, serverID: serverID)
        let server = try #require(container.listKnownServers().first)

        let client = container.makeSignInClient(for: server)
        let resolved = await container.resolveSignInRoute(for: server, client: client)

        #expect(resolved == internalURL)
        #expect(client.baseURL == internalURL)
    }

    /// The route learned here is what the session that follows starts on, so it has to be recorded.
    @Test func theResolvedRouteIsRemembered() async throws {
        let container = try container(answering: [externalURL])
        let server = try #require(container.listKnownServers().first)

        await container.resolveSignInRoute(for: server, client: container.makeSignInClient(for: server))

        #expect(container.serverRouteStore.lastRoute(serverID: serverID) == .external)
    }

    /// Nothing answers: the sign-in still needs an address to fail against and report, rather than
    /// being left pointing at nothing.
    @Test func anUnreachableServerStillGetsAnAddress() async throws {
        let container = try container(answering: [])
        container.serverRouteStore.setLastRoute(.external, serverID: serverID)
        let server = try #require(container.listKnownServers().first)

        let resolved = await container.resolveSignInRoute(
            for: server, client: container.makeSignInClient(for: server))

        #expect(resolved == externalURL)
    }

    /// Audit 2026-09-25 SESSION-1. Signing in to a second server borrowed the live client and
    /// repointed it while it still held the active session's token, so every background request
    /// (and Quick Connect's authenticate call) carried server A's token to server B.
    @Test func signingInNeverTouchesTheLiveSession() async throws {
        let container = try container(answering: [externalURL])
        let active = URL(string: "https://a.example.org")!
        container.jellyfinClient.baseURL = active
        container.jellyfinClient.accessToken = "token-of-server-a-0123456789"
        let server = try #require(container.listKnownServers().first)

        let client = container.makeSignInClient(for: server)
        await container.resolveSignInRoute(for: server, client: client)

        #expect(container.jellyfinClient.baseURL == active)
        #expect(container.jellyfinClient.accessToken == "token-of-server-a-0123456789")
        #expect(client.accessToken == nil)
        #expect(client.baseURL == externalURL)
    }

    /// Quick Connect's authenticate call runs before there is a session on that server, so it must
    /// carry no token even from a client that has one.
    @Test func quickConnectAuthenticateCarriesNoToken() {
        #expect(!JellyfinEndpoint.quickConnectAuthenticate(secret: "s").requiresAuth)
    }

    /// Audit 2026-09-25 NETWORK-2: the probe is asked for THIS server, so a host at the LAN address
    /// on another network that is some other server loses the route to the external slot.
    @Test func theProbeIsAskedForThisServersIdentity() async throws {
        let container = try container(answering: [])
        let expectedID = serverID
        let internalURL = internalURL, externalURL = externalURL
        container.jellyfinProbe = { url, id in
            url == externalURL || (url == internalURL && id != expectedID)
        }
        let server = try #require(container.listKnownServers().first)

        let resolved = await container.resolveSignInRoute(
            for: server, client: container.makeSignInClient(for: server))

        #expect(resolved == externalURL)
    }
}

/// Audit 2026-09-25 NETWORK-2: which `System/Info/Public` answers name the stored server.
@Suite("A route probe checks who answered")
struct ServerProbeIdentityTests {
    private let id = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"

    @Test func theSameServerIsRecognised() {
        #expect(ServerProbe.identifies(Data(#"{"Id":"0f1e2d3c4b5a69788796a5b4c3d2e1f0","ServerName":"Home"}"#.utf8), as: id))
        #expect(ServerProbe.identifies(Data(#"{"Id":"0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"}"#.utf8), as: id))
    }

    @Test("another server, a page without an id, or no JSON at all is not this server", arguments: [
        #"{"Id":"ffffffffffffffffffffffffffffffff"}"#,
        #"{"ServerName":"Home"}"#,
        "<html>Router login</html>",
        "",
    ])
    func somethingElseIsNot(body: String) {
        #expect(!ServerProbe.identifies(Data(body.utf8), as: id))
    }
}
