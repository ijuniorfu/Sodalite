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

    @Test func switchingToADifferentProfileDropsIt() throws {
        let keychain = InMemoryKeychain()
        let container = try containerWithPasswordSession(keychain: keychain)

        try container.switchToUser(remembered("user-b", "Guest"), server: server)

        #expect(container.loadJellyfinPassword() == nil)
        #expect(
            (try? keychain.loadString(for: KeychainKeys.jellyfinPasswordUserID(serverID: server.id))) == nil
        )
    }

    /// Pre-owner-entry installs: with no owner recorded there is no way to tell whose password it
    /// is, and keeping it would hand the previous profile's password to the next one.
    @Test func passwordWithoutAnOwnerIsDroppedOnAnySwitch() throws {
        let keychain = InMemoryKeychain()
        let container = try containerWithPasswordSession(keychain: keychain)
        try keychain.delete(for: KeychainKeys.jellyfinPasswordUserID(serverID: server.id))

        try container.switchToUser(remembered("user-a", "Vincent"), server: server)

        #expect(container.loadJellyfinPassword() == nil)
    }
}
