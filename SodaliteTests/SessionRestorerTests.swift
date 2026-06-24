import Testing
import Foundation
@testable import Sodalite

/// In-memory SessionRestoreEnvironment: inputs are settable, writes are recorded, so restore()'s
/// routing + side effects can be asserted without the real keychain. rememberUser mirrors production
/// by persisting into the backing list so the subsequent re-read reflects it.
@MainActor
final class FakeRestoreEnv: SessionRestoreEnvironment {
    var hasTVMapping = false
    var defaultServerID: String?
    var launchBehavior: AuthPreferences.LaunchBehavior = .showPicker
    var defaultUserID: String?
    var activeServer: JellyfinServer?
    var knownServers: [JellyfinServer] = []
    var remembered: [RememberedUser] = []
    var activeServerIDStored: String?
    var userIDByServer: [String: String] = [:]
    var activeUserName: String?
    var activeUserImageTag: String?
    var accessTokenByServer: [String: String] = [:]
    var restoreSessionResult = false
    var parentalControlsActiveResult = false
    var protectedKeys: Set<String> = []

    private(set) var savedActiveServerIDs: [String] = []
    private(set) var savedActiveUserImageTags: [String] = []
    private(set) var clientBaseURLs: [URL] = []
    private(set) var rememberedAdded: [RememberedUser] = []
    private(set) var switched: [String] = []

    func listKnownServers() -> [JellyfinServer] { knownServers }
    func listRememberedUsers(serverID: String) -> [RememberedUser] { remembered.filter { $0.serverID == serverID } }
    func loadActiveServerID() -> String? { activeServerIDStored }
    func loadUserID(serverID: String) -> String? { userIDByServer[serverID] }
    func loadActiveUserName() -> String? { activeUserName }
    func loadActiveUserImageTag() -> String? { activeUserImageTag }
    func loadAccessToken(serverID: String) -> String? { accessTokenByServer[serverID] }
    func restoreSession() -> Bool { restoreSessionResult }
    func parentalControlsActive() -> Bool { parentalControlsActiveResult }
    func isProtected(serverID: String, userID: String) -> Bool { protectedKeys.contains("\(serverID)|\(userID)") }
    func saveActiveServerID(_ id: String) { savedActiveServerIDs.append(id); activeServerIDStored = id }
    func saveActiveUserImageTag(_ tag: String) { savedActiveUserImageTags.append(tag) }
    func setClientBaseURL(_ url: URL) { clientBaseURLs.append(url) }
    func rememberUser(_ user: RememberedUser) throws {
        rememberedAdded.append(user)
        remembered.removeAll { $0.id == user.id && $0.serverID == user.serverID }  // upsert-by-id, as production
        remembered.append(user)
    }
    func switchToUser(_ user: RememberedUser, server: JellyfinServer) throws { switched.append(user.id) }
}

@MainActor
struct SessionRestorerTests {
    private func server(_ id: String = "A") -> JellyfinServer {
        JellyfinServer(id: id, name: "Server \(id)", url: URL(string: "https://\(id.lowercased()).example.com")!)
    }
    private func user(_ id: String, server: String = "A") -> RememberedUser {
        RememberedUser(id: id, serverID: server, name: "User \(id)", imageTag: nil, token: "tok-\(id)")
    }
    /// A fully restorable env: succeeded, server A active, user "U" globals present, no parental lock.
    private func restorable() -> FakeRestoreEnv {
        let env = FakeRestoreEnv()
        env.restoreSessionResult = true
        env.activeServer = server("A")
        env.userIDByServer["A"] = "U"
        env.activeUserName = "Main"
        return env
    }
    private func tagOf(_ o: RestoreOutcome) -> String {
        switch o {
        case .authenticated: "authenticated"
        case .picker: "picker"
        case .discovery: "discovery"
        }
    }

    @Test func noRestoreNoKnownServer_fallsToDiscovery() {
        let env = FakeRestoreEnv()
        #expect(tagOf(SessionRestorer(env: env).restore()) == "discovery")
    }

    @Test func noRestoreWithKnownServer_repairsPointerAndPicks() {
        let s = server("A")
        let env = FakeRestoreEnv()
        env.restoreSessionResult = false
        env.knownServers = [s]
        let outcome = SessionRestorer(env: env).restore()
        guard case .picker(let srv, let sync) = outcome else { Issue.record("expected picker, got \(tagOf(outcome))"); return }
        #expect(srv.id == "A")
        #expect(sync == false)
        #expect(env.savedActiveServerIDs == ["A"])   // pointer repair, not a full switch
        #expect(env.clientBaseURLs == [s.url])
    }

    @Test func restoreOkButActiveServerNil_fallsToDiscovery() {
        let env = FakeRestoreEnv()
        env.restoreSessionResult = true
        env.activeServer = nil
        #expect(tagOf(SessionRestorer(env: env).restore()) == "discovery")
    }

    @Test func restoreOkButLostUserGlobals_picksWithoutSeerrSync() {
        let env = FakeRestoreEnv()
        env.restoreSessionResult = true
        env.activeServer = server("A")
        // userID + name absent
        let outcome = SessionRestorer(env: env).restore()
        guard case .picker(_, let sync) = outcome else { Issue.record("expected picker, got \(tagOf(outcome))"); return }
        #expect(sync == false)
    }

    // SECURITY: a set PIN + any unprotected profile must force the picker even when useDefault would auto-enter.
    @Test func parentalLockForcesPicker_overridingUseDefault() {
        let env = restorable()
        env.remembered = [user("U")]            // unprotected (not in protectedKeys)
        env.parentalControlsActiveResult = true
        env.launchBehavior = .useDefault
        env.defaultUserID = "U"                 // would otherwise auto-enter
        let outcome = SessionRestorer(env: env).restore()
        guard case .picker(let srv, let sync) = outcome else { Issue.record("SECURITY REGRESSION: lock bypassed, got \(tagOf(outcome))"); return }
        #expect(srv.id == "A")
        #expect(sync == true)
        #expect(env.switched.isEmpty)           // must not silently switch into the unprotected profile
    }

    // The override only fires when an unprotected profile exists; all-protected falls through to normal routing.
    @Test func parentalLockWithAllProtected_doesNotForcePicker() {
        let env = restorable()
        env.remembered = [user("U")]
        env.parentalControlsActiveResult = true
        env.protectedKeys = ["A|U"]
        let outcome = SessionRestorer(env: env).restore()
        guard case .authenticated(_, let u) = outcome else { Issue.record("expected authenticated, got \(tagOf(outcome))"); return }
        #expect(u.id == "U")
    }

    // The imageTag re-stamp fallback: no canonical tag but the remembered blob carries one -> lift it and re-save.
    @Test func imageTagFallback_liftsFromRememberedBlobAndReStamps() {
        let env = restorable()
        env.activeUserImageTag = nil
        env.remembered = [RememberedUser(id: "U", serverID: "A", name: "Main", imageTag: "tag-xyz", token: "t")]
        let outcome = SessionRestorer(env: env).restore()
        #expect(env.savedActiveUserImageTags == ["tag-xyz"])
        guard case .authenticated(_, let u) = outcome else { Issue.record("expected authenticated, got \(tagOf(outcome))"); return }
        #expect(u.primaryImageTag == "tag-xyz")
    }

    @Test func useDefaultDifferentFromActive_authenticatesTargetAndSwitches() {
        let env = restorable()
        env.remembered = [user("U"), user("B")]
        env.launchBehavior = .useDefault
        env.defaultUserID = "B"
        let outcome = SessionRestorer(env: env).restore()
        guard case .authenticated(_, let u) = outcome else { Issue.record("expected authenticated, got \(tagOf(outcome))"); return }
        #expect(u.id == "B")
        #expect(env.switched == ["B"])
    }

    @Test func useDefaultEqualsActive_authenticatesWithoutSwitching() {
        let env = restorable()
        env.remembered = [user("U"), user("B")]
        env.launchBehavior = .useDefault
        env.defaultUserID = "U"
        let outcome = SessionRestorer(env: env).restore()
        guard case .authenticated(_, let u) = outcome else { Issue.record("expected authenticated, got \(tagOf(outcome))"); return }
        #expect(u.id == "U")
        #expect(env.switched.isEmpty)
    }

    @Test func multipleProfilesNoDefault_picksWithSeerrSync() {
        let env = restorable()
        env.remembered = [user("U"), user("B")]
        env.launchBehavior = .showPicker
        let outcome = SessionRestorer(env: env).restore()
        guard case .picker(_, let sync) = outcome else { Issue.record("expected picker, got \(tagOf(outcome))"); return }
        #expect(sync == true)
    }

    @Test func singleProfile_authenticatesDirectly() {
        let env = restorable()
        env.remembered = [user("U")]
        let outcome = SessionRestorer(env: env).restore()
        guard case .authenticated(_, let u) = outcome else { Issue.record("expected authenticated, got \(tagOf(outcome))"); return }
        #expect(u.id == "U")
        #expect(u.name == "Main")
    }

    @Test func pre030Session_migratesIntoRememberedUsers() {
        let env = restorable()
        env.accessTokenByServer["A"] = "token123"
        env.remembered = []   // active user not yet remembered
        let outcome = SessionRestorer(env: env).restore()
        #expect(env.rememberedAdded.map(\.id) == ["U"])
        #expect(tagOf(outcome) == "authenticated")   // single profile after migration
    }

    @Test func defaultServerPromotion_writesPointerBeforeRestore() {
        let env = FakeRestoreEnv()
        env.defaultServerID = "B"
        env.knownServers = [server("A"), server("B")]
        env.activeServerIDStored = "A"   // current pointer differs from the pinned default
        _ = SessionRestorer(env: env).restore()
        #expect(env.savedActiveServerIDs.first == "B")
    }

    @Test func tvMappingSuppressesDefaultServerPromotion() {
        let env = restorable()
        env.hasTVMapping = true
        env.defaultServerID = "B"
        env.knownServers = [server("A"), server("B")]
        env.activeServerIDStored = "A"
        env.remembered = [user("U")]
        _ = SessionRestorer(env: env).restore()
        #expect(!env.savedActiveServerIDs.contains("B"))
    }

    // hasTVMapping must also suppress the useDefault auto-enter branch, not just server promotion.
    @Test func tvMappingSuppressesUseDefaultBranch() {
        let env = restorable()
        env.hasTVMapping = true
        env.remembered = [user("U"), user("B")]
        env.launchBehavior = .useDefault
        env.defaultUserID = "B"
        let outcome = SessionRestorer(env: env).restore()
        guard case .picker(_, let sync) = outcome else { Issue.record("expected picker (tvMapping suppresses useDefault), got \(tagOf(outcome))"); return }
        #expect(sync == true)
        #expect(env.switched.isEmpty)
    }

    // useDefault set but the pinned default is no longer remembered: documented "silently falls back to the picker".
    @Test func useDefaultPointingAtRemovedProfile_fallsBackToPicker() {
        let env = restorable()
        env.remembered = [user("U"), user("B")]
        env.launchBehavior = .useDefault
        env.defaultUserID = "GHOST"
        let outcome = SessionRestorer(env: env).restore()
        guard case .picker(_, let sync) = outcome else { Issue.record("expected picker fallback, got \(tagOf(outcome))"); return }
        #expect(sync == true)
        #expect(env.switched.isEmpty)
    }
}
