import Foundation
import Testing
@testable import Sodalite

/// The cached Jellyfin password is keyed per server but belongs to one user, so a profile switch
/// has to drop it. Dropping it when the switch targets its *own* owner logged the user out of the
/// Seerr auto-fill they never left, and the Seerr screen then blamed Quick Connect for it.
@Suite("Jellyfin password retention across profile switches", .serialized)
@MainActor
struct JellyfinPasswordRetentionTests {
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

    private func remembered(_ id: String, _ name: String) -> RememberedUser {
        RememberedUser(id: id, serverID: server.id, name: name, imageTag: nil, token: "token-\(id)")
    }

    private func containerWithPasswordSession(
        keychain: InMemoryKeychain
    ) throws -> DependencyContainer {
        let container = DependencyContainer(keychainService: keychain)
        try container.saveSession(
            server: server,
            user: try user("user-a", "Vincent"),
            token: "token-user-a",
            password: "hunter2"
        )
        return container
    }

    @Test func passwordLoginCachesThePassword() throws {
        let keychain = InMemoryKeychain()
        let container = try containerWithPasswordSession(keychain: keychain)
        #expect(container.loadJellyfinPassword() == "hunter2")
    }

    /// Picking your own profile out of the launch picker runs the same switch as any other, and
    /// used to throw away the password that belongs to exactly that profile.
    @Test func switchingToThePasswordOwnerKeepsIt() throws {
        let keychain = InMemoryKeychain()
        let container = try containerWithPasswordSession(keychain: keychain)

        try container.switchToUser(remembered("user-a", "Vincent"), server: server)

        #expect(container.loadJellyfinPassword() == "hunter2")
    }

    /// The reported round trip: away to another profile and back. The password is the returning
    /// profile's own, so it has to be there again.
    @Test func switchingAwayAndBackKeepsIt() throws {
        let keychain = InMemoryKeychain()
        let container = try containerWithPasswordSession(keychain: keychain)

        try container.switchToUser(remembered("user-b", "Guest"), server: server)
        try container.switchToUser(remembered("user-a", "Vincent"), server: server)

        #expect(container.loadJellyfinPassword() == "hunter2")
    }

    /// Each profile keeps its own: switching must never hand one user's password to the next.
    @Test func eachProfileKeepsItsOwnPassword() throws {
        let keychain = InMemoryKeychain()
        let container = try containerWithPasswordSession(keychain: keychain)

        try container.saveSession(
            server: server,
            user: try user("user-b", "Guest"),
            token: "token-user-b",
            password: "swordfish"
        )
        #expect(container.loadJellyfinPassword() == "swordfish")

        try container.switchToUser(remembered("user-a", "Vincent"), server: server)
        #expect(container.loadJellyfinPassword() == "hunter2")

        try container.switchToUser(remembered("user-b", "Guest"), server: server)
        #expect(container.loadJellyfinPassword() == "swordfish")
    }

    /// A profile without a password of its own must not inherit the previous one's.
    @Test func switchingToADifferentProfileExposesNoPassword() throws {
        let keychain = InMemoryKeychain()
        let container = try containerWithPasswordSession(keychain: keychain)

        try container.switchToUser(remembered("user-b", "Guest"), server: server)

        #expect(container.loadJellyfinPassword() == nil)
    }

    /// Forgetting a profile takes its credentials with it, rather than leaving a password in the
    /// keychain for a profile the picker no longer shows.
    @Test func forgettingAProfileDropsItsPassword() throws {
        let keychain = InMemoryKeychain()
        let container = try containerWithPasswordSession(keychain: keychain)
        try container.rememberUser(remembered("user-a", "Vincent"))

        try container.forgetUser(id: "user-a", serverID: server.id)

        #expect(
            (try? keychain.loadString(
                for: KeychainKeys.jellyfinPassword(serverID: server.id, userID: "user-a")
            )) == nil
        )
    }

    // MARK: - Migration off the per-server layout

    /// The owner entry names whose password it was.
    @Test func legacyPasswordMovesToItsRecordedOwner() throws {
        let keychain = InMemoryKeychain()
        try seedKnownServer(in: keychain)
        try keychain.save("hunter2", for: KeychainKeys.legacyJellyfinPassword(serverID: server.id))
        try keychain.save("user-a", for: KeychainKeys.legacyJellyfinPasswordUserID(serverID: server.id))
        try keychain.save("user-b", for: KeychainKeys.userID(serverID: server.id))

        let container = DependencyContainer(keychainService: keychain)

        #expect(
            (try? keychain.loadString(
                for: KeychainKeys.jellyfinPassword(serverID: server.id, userID: "user-a")
            )) == "hunter2"
        )
        #expect((try? keychain.loadString(for: KeychainKeys.legacyJellyfinPassword(serverID: server.id))) == nil)
        _ = container
    }

    /// No owner entry: the old layout deleted the password on every profile switch, so one that is
    /// still here belonged to the server's current user.
    @Test func ownerlessLegacyPasswordGoesToTheCurrentUser() throws {
        let keychain = InMemoryKeychain()
        try seedKnownServer(in: keychain)
        try keychain.save("hunter2", for: KeychainKeys.legacyJellyfinPassword(serverID: server.id))
        try keychain.save("user-a", for: KeychainKeys.userID(serverID: server.id))

        let container = DependencyContainer(keychainService: keychain)

        #expect(container.loadJellyfinPassword() == "hunter2")
    }

    /// Nothing to attribute it to, so it does not survive as an orphan.
    @Test func ownerlessLegacyPasswordWithoutACurrentUserIsDropped() throws {
        let keychain = InMemoryKeychain()
        try seedKnownServer(in: keychain)
        try keychain.save("hunter2", for: KeychainKeys.legacyJellyfinPassword(serverID: server.id))

        let container = DependencyContainer(keychainService: keychain)

        #expect((try? keychain.loadString(for: KeychainKeys.legacyJellyfinPassword(serverID: server.id))) == nil)
        #expect(container.loadJellyfinPassword() == nil)
    }

    private func seedKnownServer(in keychain: InMemoryKeychain) throws {
        try keychain.save(try JSONEncoder().encode([server]), for: KeychainKeys.knownServers)
        try keychain.save(server.id, for: KeychainKeys.activeServerID)
    }
}
