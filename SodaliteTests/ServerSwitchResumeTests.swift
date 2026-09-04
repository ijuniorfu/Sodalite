import Foundation
import Testing
@testable import Sodalite

/// A server restored from iCloud arrives with its remembered profiles (tokens included) but with no
/// session slot of its own: that slot is device-local and never syncs. Switching to such a server used
/// to fail on `.missingToken` while the credential sat right there in the remembered profile
/// (Sodalite#74). Resuming is only automatic where the pick is unambiguous; everything else belongs to
/// the profile picker, which is also what the throw now routes to.
@Suite("Switching to a server with no session of its own", .serialized)
@MainActor
struct ServerSwitchResumeTests {
    private let serverA = JellyfinServer(id: "A", name: "Server A", url: URL(string: "https://a.example.com")!)
    private let serverB = JellyfinServer(id: "B", name: "Server B", url: URL(string: "https://b.example.com")!)

    private func profile(_ id: String) -> RememberedUser {
        RememberedUser(id: id, serverID: "B", name: "User \(id)", imageTag: nil, token: "tok-\(id)")
    }

    /// Signed into A, B known and carrying profiles but no token slot: the shape a clean install with
    /// iCloud sync leaves behind for every server that is not the active one.
    private func twoServerDevice(profilesOnB: [RememberedUser]) throws -> DependencyContainer {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        try container.addServer(serverB)
        try container.addServer(serverA)
        try container.keychainService.save("tok-A", for: KeychainKeys.accessToken(serverID: "A"))
        try container.keychainService.save("user-a", for: KeychainKeys.userID(serverID: "A"))
        try container.keychainService.save("A", for: KeychainKeys.activeServerID)
        container.jellyfinClient.baseURL = serverA.url
        container.jellyfinClient.accessToken = "tok-A"
        for user in profilesOnB {
            try container.rememberUser(user)
        }
        return container
    }

    private func stored(_ container: DependencyContainer, _ key: String) -> String? {
        try? container.keychainService.loadString(for: key)
    }

    @Test func theOnlyRememberedProfileIsResumedWithoutAsking() throws {
        let container = try twoServerDevice(profilesOnB: [profile("u1")])

        try container.switchServer(to: "B")

        #expect(stored(container, KeychainKeys.activeServerID) == "B")
        #expect(stored(container, KeychainKeys.accessToken(serverID: "B")) == "tok-u1")
        #expect(stored(container, KeychainKeys.userID(serverID: "B")) == "u1")
        #expect(stored(container, KeychainKeys.activeUserName) == "User u1")
        #expect(container.jellyfinClient.accessToken == "tok-u1")
        #expect(container.jellyfinClient.baseURL == serverB.url)
    }

    @Test func thePinnedProfileDecidesWhenSeveralAreRemembered() throws {
        let container = try twoServerDevice(profilesOnB: [profile("u1"), profile("u2"), profile("u3")])
        container.authPreferences.setDefaultUserID("u2", serverID: "B")
        defer { container.authPreferences.setDefaultUserID(nil, serverID: "B") }

        try container.switchServer(to: "B")

        #expect(stored(container, KeychainKeys.userID(serverID: "B")) == "u2")
        #expect(container.jellyfinClient.accessToken == "tok-u2")
    }

    /// Several profiles and nothing pinned: which of them is watching is not the app's to guess, and
    /// "most recently added" is a statement about another device anyway.
    @Test func severalUnpinnedProfilesAskInsteadOfGuessing() throws {
        let container = try twoServerDevice(profilesOnB: [profile("u1"), profile("u2")])

        #expect(throws: DependencyContainer.ServerSwitchError.missingToken) {
            try container.switchServer(to: "B")
        }
        #expect(container.resumableProfile(serverID: "B") == nil)
    }

    @Test func aServerWithoutRememberedProfilesAsksForASignIn() throws {
        let container = try twoServerDevice(profilesOnB: [])

        #expect(throws: DependencyContainer.ServerSwitchError.missingToken) {
            try container.switchServer(to: "B")
        }
    }

    /// The throw lands before the first write, so the session the user is in survives a switch that
    /// cannot complete. The old code moved the pointer first and left both call sites rolling it back.
    @Test func aSwitchThatCannotCompleteLeavesTheCurrentSessionAlone() throws {
        let container = try twoServerDevice(profilesOnB: [profile("u1"), profile("u2")])

        try? container.switchServer(to: "B")

        #expect(stored(container, KeychainKeys.activeServerID) == "A")
        #expect(stored(container, KeychainKeys.accessToken(serverID: "B")) == nil)
        #expect(container.jellyfinClient.accessToken == "tok-A")
        #expect(container.jellyfinClient.baseURL == serverA.url)
    }

    /// Guardian PIN set and the single card unprotected: the picker would ask for the PIN before
    /// activating it, so resuming it unasked would walk straight around the lock.
    @Test func aProfileTheGuardianPINGuardsIsNotResumedUnasked() throws {
        let container = try twoServerDevice(profilesOnB: [profile("u1")])
        try container.saveGuardianPIN("1234")
        container.parentalControlsPreferences.setRole(.pinToLeave, serverID: "A", userID: "user-a")
        defer { container.parentalControlsPreferences.setRole(.open, serverID: "A", userID: "user-a") }

        #expect(container.resumableProfile(serverID: "B") == nil)
        #expect(throws: DependencyContainer.ServerSwitchError.missingToken) {
            try container.switchServer(to: "B")
        }
    }

    /// A protected card is free to enter in the picker too, so resuming it changes nothing about who
    /// gets past the lock.
    @Test func aProtectedProfileIsStillResumed() throws {
        let container = try twoServerDevice(profilesOnB: [profile("u1")])
        try container.saveGuardianPIN("1234")
        container.parentalControlsPreferences.setRole(.pinToLeave, serverID: "B", userID: "u1")
        defer { container.parentalControlsPreferences.setRole(.open, serverID: "B", userID: "u1") }

        try container.switchServer(to: "B")

        #expect(container.jellyfinClient.accessToken == "tok-u1")
    }

    /// The device's own token slot stays the first reading; the remembered profile is only consulted
    /// where that slot is empty, so a switch never re-points a server at another profile.
    @Test func theDevicesOwnSessionWinsOverTheRememberedProfiles() throws {
        let container = try twoServerDevice(profilesOnB: [profile("u1"), profile("u2")])
        try container.keychainService.save("own-tok-B", for: KeychainKeys.accessToken(serverID: "B"))
        try container.keychainService.save("u2", for: KeychainKeys.userID(serverID: "B"))

        try container.switchServer(to: "B")

        #expect(container.jellyfinClient.accessToken == "own-tok-B")
        #expect(stored(container, KeychainKeys.userID(serverID: "B")) == "u2")
    }

    /// Deleting the active server promotes a survivor. switchServer no longer half-switches on the way
    /// out, so the promotion has to move the pointer itself, else the active-server entry keeps naming
    /// the server that was just deleted.
    @Test func removingTheActiveServerPromotesASuccessorItCannotResume() throws {
        let container = try twoServerDevice(profilesOnB: [profile("u1"), profile("u2")])

        try container.removeServer(id: "A")

        #expect(stored(container, KeychainKeys.activeServerID) == "B")
        #expect(container.jellyfinClient.baseURL == serverB.url)
        #expect(container.jellyfinClient.accessToken == nil)
    }

    @Test func removingTheActiveServerResumesASuccessorItCan() throws {
        let container = try twoServerDevice(profilesOnB: [profile("u1")])

        try container.removeServer(id: "A")

        #expect(stored(container, KeychainKeys.activeServerID) == "B")
        #expect(container.jellyfinClient.accessToken == "tok-u1")
    }
}
