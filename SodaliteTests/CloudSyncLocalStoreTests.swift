import Foundation
import Testing
@testable import Sodalite

/// In-memory KeychainServiceProtocol so the container round-trips without SecItem.
final class InMemoryKeychain: KeychainServiceProtocol, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    func save(_ data: Data, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = data
    }
    func save(_ string: String, for key: String) throws {
        try save(Data(string.utf8), for: key)
    }
    func loadData(for key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }
    func loadString(for key: String) throws -> String? {
        try loadData(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }
    func delete(for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
    func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}

@Suite("CloudSync local collect/apply", .serialized)
@MainActor
struct CloudSyncLocalStoreTests {
    private func makeContainer() -> DependencyContainer {
        DependencyContainer(keychainService: InMemoryKeychain())
    }

    private var sampleServer: JellyfinServer {
        JellyfinServer(id: "srv1", name: "Main", url: URL(string: "https://jf.example")!, version: "10.10")
    }

    @Test("server payload round-trips through keychain")
    func serverRoundTrip() throws {
        let source = makeContainer()
        try source.addServer(sampleServer)
        try source.rememberUser(RememberedUser(id: "u1", serverID: "srv1", name: "vincent", imageTag: nil, token: "tok1"))

        let payload = source.collectServerPayload(serverID: "srv1", stamp: Date(timeIntervalSince1970: 7))
        let unwrapped = try #require(payload)
        #expect(unwrapped.server == sampleServer)
        #expect(unwrapped.rememberedUsers.map(\.id) == ["u1"])
        #expect(unwrapped.updatedAt == Date(timeIntervalSince1970: 7))

        let target = makeContainer()
        target.applyServerPayload(unwrapped)
        #expect(target.listKnownServers() == [sampleServer])
        #expect(target.listRememberedUsers(serverID: "srv1").map(\.id) == ["u1"])
    }

    @Test("collect returns nil for an unknown server")
    func collectUnknown() {
        #expect(makeContainer().collectServerPayload(serverID: "nope", stamp: Date()) == nil)
    }

    @Test("apply upserts without reordering existing servers")
    func applyKeepsOrder() throws {
        let container = makeContainer()
        try container.addServer(sampleServer)
        let second = JellyfinServer(id: "srv2", name: "Second", url: URL(string: "https://two.example")!, version: nil)
        let payload = ServerSyncPayload(updatedAt: Date(), server: second, rememberedUsers: [],
                                        jellyfinPassword: nil, passwordUserID: nil, seerrSessions: [], homeRows: nil)
        container.applyServerPayload(payload)
        // Remote-added server appends; it must not hijack the local MRU front slot.
        #expect(container.listKnownServers().map(\.id) == ["srv1", "srv2"])
    }

    @Test("remote server deletion removes all scoped state")
    func remoteDeletion() throws {
        let container = makeContainer()
        try container.addServer(sampleServer)
        try container.rememberUser(RememberedUser(id: "u1", serverID: "srv1", name: "v", imageTag: nil, token: "t"))
        container.applyRemoteServerDeletion(serverID: "srv1")
        #expect(container.listKnownServers().isEmpty)
        #expect(container.listRememberedUsers(serverID: "srv1").isEmpty)
    }

    @Test("settings payloads round-trip through the stores")
    func settingsRoundTrip() {
        let source = makeContainer()
        source.appearancePreferences.accentChoice = .ocean
        source.appearancePreferences.largeCards = true
        let payload = source.collectSettingsPayload(.appearance, stamp: Date(timeIntervalSince1970: 3))
        guard case .appearance(let inner) = payload else { Issue.record("wrong case"); return }
        #expect(inner.accentChoice == "ocean")
        #expect(inner.largeCards == true)

        let target = makeContainer()
        target.applySettingsPayload(payload)
        #expect(target.appearancePreferences.accentChoice == .ocean)
        #expect(target.appearancePreferences.largeCards == true)
    }

    @Test("unknown enum raw value keeps the current store value")
    func enumFallback() {
        let container = makeContainer()
        container.appearancePreferences.accentChoice = .gold
        let payload = SettingsSyncPayload.appearance(AppearanceSettingsPayload(
            updatedAt: Date(), accentChoice: "fromTheFuture", showContentLogos: true,
            continueWatchingImage: "still", largeCards: false, nowPlayingUsesSeriesPoster: false))
        container.applySettingsPayload(payload)
        #expect(container.appearancePreferences.accentChoice == .gold)
    }

    @Test("security payload round-trips the PIN blob")
    func securityRoundTrip() throws {
        let source = makeContainer()
        try source.saveGuardianPIN("2468")
        let payload = try #require(source.collectSecurityPayload(stamp: Date(timeIntervalSince1970: 9)))

        let target = makeContainer()
        target.applySecurityPayload(payload)
        #expect(target.isGuardianPINSet())
        #expect(target.verifyGuardianPIN("2468") == .success)
        target.applyRemoteSecurityDeletion()
        #expect(!target.isGuardianPINSet())
    }
}
