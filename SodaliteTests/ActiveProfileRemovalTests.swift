import Foundation
import Testing
@testable import Sodalite

/// Sodalite#90. Ending a profile used to mean two different things depending on where it was done:
/// the picker's forget left the session alone, and the 401 path rewrote the remembered list by hand,
/// without a tombstone and without touching the credentials. Both go through `dropActiveProfile`
/// now, and the signed-in profile can finally be removed without a full logout taking every server
/// with it.
@Suite("Removing the signed-in profile", .serialized)
@MainActor
struct ActiveProfileRemovalTests {
    private let server = JellyfinServer(
        id: "srv-90", name: "Home", internalURL: URL(string: "http://10.0.0.2:8096"), externalURL: nil
    )

    private func user(_ id: String, _ name: String) throws -> JellyfinUser {
        try JSONDecoder().decode(
            JellyfinUser.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(name)","ServerId":"srv-90"}"#.utf8)
        )
    }

    private func signedIn(
        keychain: InMemoryKeychain,
        password: String? = "hunter2"
    ) throws -> DependencyContainer {
        let container = DependencyContainer(keychainService: keychain)
        try container.saveSession(
            server: server,
            user: try user("user-a", "Vincent"),
            token: "token-user-a",
            password: password
        )
        return container
    }

    @Test func theProfileAndItsSessionGoTogether() throws {
        let keychain = InMemoryKeychain()
        let container = try signedIn(keychain: keychain)

        container.dropActiveProfile(serverID: server.id, userID: "user-a")

        #expect(container.listRememberedUsers(serverID: server.id).isEmpty)
        #expect((try? keychain.loadString(for: KeychainKeys.accessToken(serverID: server.id))) == nil)
        #expect((try? keychain.loadString(for: KeychainKeys.userID(serverID: server.id))) == nil)
        #expect(container.jellyfinClient.accessToken == nil)
    }

    /// The removal has to travel as a removal, else the next iCloud fetch hands the profile back
    /// (Sodalite#45's union merge).
    @Test func theRemovalIsRecordedAsATombstone() throws {
        let container = try signedIn(keychain: InMemoryKeychain())

        container.dropActiveProfile(serverID: server.id, userID: "user-a")

        #expect(container.listForgottenUsers(serverID: server.id)["user-a"] != nil)
    }

    /// A profile that is gone must not leave its password behind: on this path the password is
    /// exactly what the server just refused.
    @Test func theProfilesCredentialsGoWithIt() throws {
        let keychain = InMemoryKeychain()
        let container = try signedIn(keychain: keychain)
        #expect(container.loadJellyfinPassword() == "hunter2")

        container.dropActiveProfile(serverID: server.id, userID: "user-a")

        let password = try? keychain.loadString(
            for: KeychainKeys.jellyfinPassword(serverID: server.id, userID: "user-a")
        )
        #expect(password == nil)
    }

    /// The server itself stays known: signing out of a profile is not signing out of the server, so
    /// the picker the session lands on still has one to offer profiles for.
    @Test func theServerSurvivesTheProfile() throws {
        let container = try signedIn(keychain: InMemoryKeychain())

        container.dropActiveProfile(serverID: server.id, userID: "user-a")

        #expect(container.listKnownServers().map(\.id) == [server.id])
    }

    /// The routing is a serverDidSwitch bump: AppRouter's probe finds no session and lands on the
    /// picker in the same update, which is what keeps the discovery screen from flashing between.
    @Test func signingOutAsksTheRouterToReResolve() throws {
        let container = try signedIn(keychain: InMemoryKeychain())
        let appState = AppState()
        container.appState = appState
        let before = appState.serverDidSwitch

        container.signOutOfActiveProfile()

        #expect(container.listRememberedUsers(serverID: server.id).isEmpty)
        #expect(appState.serverDidSwitch == before + 1)
    }

    /// A pin naming a profile that is gone would send the next launch after a ghost. It is cleared
    /// where the profile is removed, not at the call sites, so no path can forget to.
    @Test func aDefaultPinNamingTheProfileIsCleared() throws {
        let container = try signedIn(keychain: InMemoryKeychain())
        container.authPreferences.setDefaultUserID("user-a", serverID: server.id)

        try container.forgetUser(id: "user-a", serverID: server.id)

        #expect(container.authPreferences.defaultUserID(serverID: server.id) == nil)
    }

    @Test func aPinNamingAnotherProfileStands() throws {
        let container = try signedIn(keychain: InMemoryKeychain())
        container.authPreferences.setDefaultUserID("user-b", serverID: server.id)

        try container.forgetUser(id: "user-a", serverID: server.id)

        #expect(container.authPreferences.defaultUserID(serverID: server.id) == "user-b")
    }
}
