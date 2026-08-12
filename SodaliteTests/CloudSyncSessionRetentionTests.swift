import Foundation
import Testing
@testable import Sodalite

/// Sodalite#45. A server record carries per-profile Jellyseerr sessions, and a device where nobody
/// signed into Jellyseerr collects none. Treating that as "there are none" let such a device sign
/// every other device out, permanently and without a race: the asymmetry is the setup, not timing.
@Suite("Seerr session retention across server payloads", .serialized)
@MainActor
struct CloudSyncSessionRetentionTests {
    private let server = JellyfinServer(
        id: "srv1", name: "Home", internalURL: URL(string: "http://10.0.0.2:8096"), externalURL: nil
    )
    private let seerr = SeerrServer(id: "seerr-1", url: URL(string: "http://10.0.0.2:5055")!)

    private func container() -> DependencyContainer {
        DependencyContainer(keychainService: InMemoryKeychain())
    }

    private func user(_ id: String, _ name: String) -> RememberedUser {
        RememberedUser(id: id, serverID: "srv1", name: name, imageTag: nil, token: "token-\(id)")
    }

    /// Device with a Jellyseerr session for one profile.
    private func connected(users: [RememberedUser]) throws -> DependencyContainer {
        let container = container()
        try container.addServer(server)
        for user in users { try container.rememberUser(user) }
        container.seerrClient.sessionCookie = "connect.sid=abc"
        try container.saveSeerrSession(
            server: seerr, forJellyfinUserID: "user-a", jellyfinServerID: "srv1"
        )
        return container
    }

    /// Device that knows the same profiles but has never set Jellyseerr up.
    private func seerrless(users: [RememberedUser]) throws -> DependencyContainer {
        let container = container()
        try container.addServer(server)
        for user in users { try container.rememberUser(user) }
        return container
    }

    @Test func aSeerrlessDevicePayloadKeepsTheSession() throws {
        let withSeerr = try connected(users: [user("user-a", "Vincent")])
        let without = try seerrless(users: [user("user-a", "Vincent")])

        let payload = try #require(without.collectServerPayload(serverID: "srv1", stamp: Date()))
        #expect(payload.seerrSessions.isEmpty)
        withSeerr.applyServerPayload(payload)

        #expect(withSeerr.restoreSeerrSession(
            forJellyfinUserID: "user-a", jellyfinServerID: "srv1"
        ) != nil)
    }

    /// The cleanup the sweep existed for stays: a profile the payload dropped must not leave its
    /// Jellyseerr entry behind.
    @Test func aDroppedProfileStillLosesItsSession() throws {
        let withSeerr = try connected(users: [user("user-a", "Vincent"), user("user-b", "Guest")])
        let other = try seerrless(users: [user("user-b", "Guest")])

        let payload = try #require(other.collectServerPayload(serverID: "srv1", stamp: Date()))
        withSeerr.applyServerPayload(payload)

        #expect(withSeerr.restoreSeerrSession(
            forJellyfinUserID: "user-a", jellyfinServerID: "srv1"
        ) == nil)
    }

    /// A payload that does carry a session still wins for that profile.
    @Test func anIncomingSessionReplacesTheLocalOne() throws {
        let target = try connected(users: [user("user-a", "Vincent")])

        let source = container()
        try source.addServer(server)
        try source.rememberUser(user("user-a", "Vincent"))
        source.seerrClient.sessionCookie = "connect.sid=newer"
        try source.saveSeerrSession(
            server: SeerrServer(id: "seerr-2", url: URL(string: "https://seerr.example.com")!),
            forJellyfinUserID: "user-a",
            jellyfinServerID: "srv1"
        )

        let payload = try #require(source.collectServerPayload(serverID: "srv1", stamp: Date()))
        target.applyServerPayload(payload)

        let restored = target.restoreSeerrSession(forJellyfinUserID: "user-a", jellyfinServerID: "srv1")
        #expect(restored?.externalURL == URL(string: "https://seerr.example.com"))
    }
}
