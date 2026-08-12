import Foundation
import Testing
@testable import Sodalite

/// Sodalite#45. The remembered-profile list used to travel as an authoritative blob, so a device
/// whose list was behind pruned profiles (and their tokens) everywhere. A union alone cannot be the
/// answer either: "Forget Profile" has to keep travelling, and under a union the other devices would
/// hand the profile straight back. So a removal is published as such, and only a deliberate re-add
/// takes it back.
@Suite("Forgotten profiles travel without pruning", .serialized)
@MainActor
struct CloudSyncProfileTombstoneTests {
    private let server = JellyfinServer(
        id: "srv1", name: "Home", internalURL: URL(string: "http://10.0.0.2:8096"), externalURL: nil
    )

    private func container() -> DependencyContainer {
        DependencyContainer(keychainService: InMemoryKeychain())
    }

    private func user(_ id: String, at seconds: TimeInterval = 1) -> RememberedUser {
        RememberedUser(
            id: id, serverID: "srv1", name: id, imageTag: nil, token: "token-\(id)",
            addedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func device(users: [RememberedUser]) throws -> DependencyContainer {
        let container = container()
        try container.addServer(server)
        for user in users { try container.rememberUser(user) }
        return container
    }

    private func profileIDs(_ container: DependencyContainer) -> [String] {
        container.listRememberedUsers(serverID: "srv1").map(\.id).sorted()
    }

    private func payload(_ container: DependencyContainer) throws -> ServerSyncPayload {
        try #require(container.collectServerPayload(serverID: "srv1", stamp: Date()))
    }

    @Test func aDevicePayloadThatIsBehindKeepsBothProfiles() throws {
        let ahead = try device(users: [user("user-a"), user("user-b")])
        let behind = try device(users: [user("user-a")])

        ahead.applyServerPayload(try payload(behind))

        #expect(profileIDs(ahead) == ["user-a", "user-b"])
    }

    @Test func aForgottenProfileTravels() throws {
        let source = try device(users: [user("user-a"), user("user-b")])
        let target = try device(users: [user("user-a"), user("user-b")])

        try source.forgetUser(id: "user-b", serverID: "srv1")
        target.applyServerPayload(try payload(source))

        #expect(profileIDs(target) == ["user-a"])
    }

    /// The reason a plain union is not enough: the other device has not heard yet and its next
    /// payload still lists the profile.
    @Test func aStalePayloadDoesNotResurrectAForgottenProfile() throws {
        let source = try device(users: [user("user-a"), user("user-b")])
        let stale = try device(users: [user("user-a"), user("user-b")])
        let stalePayload = try payload(stale)

        try source.forgetUser(id: "user-b", serverID: "srv1")
        source.applyServerPayload(stalePayload)

        #expect(profileIDs(source) == ["user-a"])
    }

    /// A forgotten profile takes its credentials with it on the receiving device too, the same
    /// teardown a local forget does.
    @Test func aForgottenProfilePurgesItsCredentialsOnTheOtherDevice() throws {
        let source = try device(users: [user("user-a"), user("user-b")])
        let target = try device(users: [user("user-a"), user("user-b")])
        try target.keychainService.save(
            "hunter2", for: KeychainKeys.jellyfinPassword(serverID: "srv1", userID: "user-b")
        )

        try source.forgetUser(id: "user-b", serverID: "srv1")
        target.applyServerPayload(try payload(source))

        let leftover = try target.keychainService.loadString(
            for: KeychainKeys.jellyfinPassword(serverID: "srv1", userID: "user-b")
        )
        #expect(leftover == nil)
    }

    /// Signing back in as that profile is the deliberate act that takes the removal back.
    @Test func signingBackInTakesTheRemovalBack() throws {
        let source = try device(users: [user("user-a"), user("user-b")])
        try source.forgetUser(id: "user-b", serverID: "srv1")
        try source.rememberUser(user("user-b", at: 99))

        let target = try device(users: [user("user-a")])
        target.applyServerPayload(try payload(source))

        #expect(profileIDs(target) == ["user-a", "user-b"])
    }

    /// The trap a removal without a date walks into: the device that learned the removal would hand
    /// it back to the device that took it back, forever, and the profile could never return. The
    /// sign-in is newer than the removal, and that is what settles it.
    @Test func aReAddSurvivesTheOtherDevicesTombstone() throws {
        let removing = try device(users: [user("user-a"), user("user-b")])
        try removing.forgetUser(id: "user-b", serverID: "srv1")

        let readding = try device(users: [user("user-a"), user("user-b")])
        readding.applyServerPayload(try payload(removing))
        #expect(profileIDs(readding) == ["user-a"])

        try readding.rememberUser(user("user-b", at: Date().timeIntervalSince1970 + 60))
        removing.applyServerPayload(try payload(readding))

        #expect(profileIDs(removing) == ["user-a", "user-b"])
        #expect(removing.listForgottenUsers(serverID: "srv1").isEmpty)
    }

    /// And the other direction still holds: a sign-in OLDER than the removal is the stale device's
    /// existing entry, not a re-add.
    @Test func anOlderSignInDoesNotOutrankTheRemoval() throws {
        let source = try device(users: [user("user-a"), user("user-b", at: 10)])
        try source.forgetUser(id: "user-b", serverID: "srv1")

        let target = try device(users: [user("user-a"), user("user-b", at: 10)])
        target.applyServerPayload(try payload(source))

        #expect(profileIDs(target) == ["user-a"])
    }

    /// A profile added on the other device is newer than what this payload knows, so the union
    /// keeps the newer entry rather than the payload's.
    @Test func theUnionKeepsTheNewerEntryPerProfile() throws {
        let target = try device(users: [user("user-a", at: 50)])
        let source = try device(users: [user("user-a", at: 10)])

        target.applyServerPayload(try payload(source))

        let entry = try #require(target.listRememberedUsers(serverID: "srv1").first)
        #expect(entry.addedAt == Date(timeIntervalSince1970: 50))
    }
}

/// The default-server pin used to ride the global auth record, where a device that never pinned
/// anything published `nil` and cleared everyone else's pin: an absent pin and a deliberately
/// cleared one are indistinguishable there. It rides the server record now, like the per-server
/// profile pin already does, so only a device that knows the server can speak about it.
@Suite("Default server pin rides the server record", .serialized)
@MainActor
struct CloudSyncDefaultServerPinTests {
    private let server = JellyfinServer(
        id: "srv1", name: "Home", internalURL: URL(string: "http://10.0.0.2:8096"), externalURL: nil
    )

    /// The auth store is on UserDefaults.standard, which every container in the process shares, so
    /// the incoming side is a hand-built payload rather than a second device.
    private func withContainer(_ perform: (DependencyContainer) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "auth.defaultServerID")
        defer {
            if let previous { defaults.set(previous, forKey: "auth.defaultServerID") }
            else { defaults.removeObject(forKey: "auth.defaultServerID") }
        }
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        container.setDefaultServer(nil)
        try container.addServer(server)
        try perform(container)
    }

    private func serverPayload(isDefaultServer: Bool?) -> ServerSyncPayload {
        ServerSyncPayload(
            updatedAt: Date(),
            server: server,
            rememberedUsers: [],
            jellyfinPassword: nil,
            passwordUserID: nil,
            jellyfinPasswords: nil,
            seerrSessions: [],
            homeRows: nil,
            defaultUserID: nil,
            forgottenUsers: nil,
            isDefaultServer: isDefaultServer
        )
    }

    @Test func thePinItCollectsIsTheServersOwn() throws {
        try withContainer { container in
            container.setDefaultServer("srv1")
            let payload = try #require(container.collectServerPayload(serverID: "srv1", stamp: Date()))
            #expect(payload.isDefaultServer == true)
        }
    }

    @Test func aPinnedServerTravels() throws {
        try withContainer { container in
            container.applyServerPayload(serverPayload(isDefaultServer: true))
            #expect(container.authPreferences.defaultServerID == "srv1")
        }
    }

    @Test func unpinningTravels() throws {
        try withContainer { container in
            container.setDefaultServer("srv1")
            container.applyServerPayload(serverPayload(isDefaultServer: false))
            #expect(container.authPreferences.defaultServerID == nil)
        }
    }

    /// A record from a build that predates the move carries no opinion, so it must not clear a pin.
    @Test func aRecordWithoutTheFieldLeavesThePinAlone() throws {
        try withContainer { container in
            container.setDefaultServer("srv1")
            container.applyServerPayload(serverPayload(isDefaultServer: nil))
            #expect(container.authPreferences.defaultServerID == "srv1")
        }
    }

    /// The regression this moved for: the global auth record cannot tell "never pinned" from
    /// "deliberately cleared", so a device without a pin used to clear everyone else's.
    @Test func anAuthPayloadWithoutAPinLeavesItAlone() throws {
        try withContainer { container in
            container.setDefaultServer("srv1")
            container.applySettingsPayload(.auth(AuthSettingsPayload(
                updatedAt: Date(),
                launchBehavior: AuthPreferences.LaunchBehavior.showPicker.rawValue,
                defaultUserID: nil,
                defaultServerID: nil,
                profileReprompt: nil
            )))
            #expect(container.authPreferences.defaultServerID == "srv1")
        }
    }
}
