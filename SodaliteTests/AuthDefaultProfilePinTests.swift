import Testing
import Foundation
@testable import Sodalite

/// The default-profile pin is scoped per server: a profile only means anything inside one server's
/// profile list, and the retired single slot let pinning on one server silently unpin the other.
@MainActor
struct AuthDefaultProfilePinTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.authPin.\(UUID().uuidString)")!
    }

    @Test func pinIsPerServer() {
        let prefs = AuthPreferences(store: isolatedDefaults())
        prefs.setDefaultUserID("U", serverID: "A")
        prefs.setDefaultUserID("V", serverID: "B")
        #expect(prefs.defaultUserID(serverID: "A") == "U")
        #expect(prefs.defaultUserID(serverID: "B") == "V")
    }

    @Test func pinningOnOneServerLeavesTheOtherAlone() {
        let prefs = AuthPreferences(store: isolatedDefaults())
        prefs.setDefaultUserID("U", serverID: "A")
        prefs.setDefaultUserID("V", serverID: "B")
        prefs.setDefaultUserID(nil, serverID: "B")
        #expect(prefs.defaultUserID(serverID: "A") == "U")
        #expect(prefs.defaultUserID(serverID: "B") == nil)
    }

    @Test func persistsAcrossInstances() {
        let store = isolatedDefaults()
        AuthPreferences(store: store).setDefaultUserID("U", serverID: "A")
        #expect(AuthPreferences(store: store).defaultUserID(serverID: "A") == "U")
    }

    @Test func legacyPinMovesOntoTheGivenServer() {
        let store = isolatedDefaults()
        store.set("LEGACY", forKey: "auth.defaultUserID")
        let prefs = AuthPreferences(store: store)
        prefs.migrateLegacyDefaultUserID(toServerID: "A")
        #expect(prefs.defaultUserID(serverID: "A") == "LEGACY")
        #expect(store.string(forKey: "auth.defaultUserID") == nil)   // never resurfaces on a third server
    }

    @Test func legacyPinIsDroppedWhenNoServerCanOwnIt() {
        let store = isolatedDefaults()
        store.set("LEGACY", forKey: "auth.defaultUserID")
        AuthPreferences(store: store).migrateLegacyDefaultUserID(toServerID: nil)
        #expect(store.string(forKey: "auth.defaultUserID") == nil)
    }

    @Test func legacyPinDoesNotOverwriteAnExistingScopedPin() {
        let store = isolatedDefaults()
        store.set("LEGACY", forKey: "auth.defaultUserID")
        let prefs = AuthPreferences(store: store)
        prefs.setDefaultUserID("SCOPED", serverID: "A")
        prefs.migrateLegacyDefaultUserID(toServerID: "A")
        #expect(prefs.defaultUserID(serverID: "A") == "SCOPED")
    }
}
