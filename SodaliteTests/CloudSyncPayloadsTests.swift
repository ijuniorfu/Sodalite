import Foundation
import Testing
@testable import Sodalite

private struct LegacyAppearancePayload: Encodable {
    let schemaVersion = 1
    let updatedAt: Date
    let accentChoice: String
    let showContentLogos: Bool
    let continueWatchingImage: String
    let largeCards: Bool
    let nowPlayingUsesSeriesPoster: Bool
}

@Suite("CloudSync payload round-trips")
struct CloudSyncPayloadsTests {
    @Test("server payload JSON round-trip")
    func serverRoundTrip() throws {
        let payload = ServerSyncPayload(
            updatedAt: Date(timeIntervalSince1970: 1_000_000),
            server: JellyfinServer(id: "s1", name: "Main", url: URL(string: "https://jf.example")!, version: "10.10"),
            rememberedUsers: [RememberedUser(id: "u1", serverID: "s1", name: "vincent", imageTag: nil, token: "tok", addedAt: Date(timeIntervalSince1970: 500))],
            jellyfinPassword: "pw",
            passwordUserID: "u1",
            seerrSessions: [RememberedSeerrSession(jellyfinUserID: "u1", jellyfinServerID: "s1", seerrServer: SeerrServer(id: "se1", url: URL(string: "https://seerr.example")!), cookie: "cookie")],
            homeRows: HomeRowsSyncState(configsJSON: Data("[]".utf8), mergeCWNextUp: true, rewatchNextUp: false)
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ServerSyncPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test("settings payload encodes and decodes by store key")
    func settingsRoundTrip() throws {
        let payload = SettingsSyncPayload.appearance(AppearanceSettingsPayload(
            updatedAt: Date(timeIntervalSince1970: 42),
            accentChoice: "ocean",
            backgroundStyle: BackgroundStyle.cinemaNoir.rawValue,
            showContentLogos: false,
            continueWatchingImage: "backdrop",
            largeCards: true,
            nowPlayingUsesSeriesPoster: false
        ))
        let data = try payload.encoded()
        let decoded = try SettingsSyncPayload.decode(data, key: .appearance)
        #expect(decoded == payload)
    }

    @Test("appearance schema 1 defaults background to graphite")
    func appearanceSchema1Default() throws {
        let legacy = LegacyAppearancePayload(
            updatedAt: Date(timeIntervalSince1970: 42),
            accentChoice: "ocean",
            showContentLogos: false,
            continueWatchingImage: "backdrop",
            largeCards: true,
            nowPlayingUsesSeriesPoster: false
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try SettingsSyncPayload.decode(data, key: .appearance)
        guard case .appearance(let payload) = decoded else {
            Issue.record("wrong payload case")
            return
        }
        #expect(payload.schemaVersion == 1)
        #expect(payload.backgroundStyle == BackgroundStyle.graphiteGlass.rawValue)
    }

    @Test("decoded legacy appearance re-encodes as schema 2")
    func legacyAppearanceReencodesAsSchema2() throws {
        let legacy = LegacyAppearancePayload(
            updatedAt: Date(timeIntervalSince1970: 42),
            accentChoice: "ocean",
            showContentLogos: false,
            continueWatchingImage: "backdrop",
            largeCards: true,
            nowPlayingUsesSeriesPoster: false
        )
        let legacyData = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(
            AppearanceSettingsPayload.self,
            from: legacyData
        )
        #expect(decoded.schemaVersion == 1)

        let reencoded = try JSONEncoder().encode(decoded)
        let object = try #require(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 2)
    }

    @Test("record names round-trip to ids")
    func recordNames() {
        #expect(CloudSyncRecordName.server(id: "abc") == "server-abc")
        #expect(CloudSyncRecordName.serverID(fromRecordName: "server-abc") == "abc")
        #expect(CloudSyncRecordName.serverID(fromRecordName: "settings-playback") == nil)
        #expect(CloudSyncRecordName.storeKey(fromRecordName: "settings-playback") == .playback)
        #expect(CloudSyncRecordName.storeKey(fromRecordName: "server-abc") == nil)
    }

    @Test("restamped changes only updatedAt")
    func restamped() throws {
        let original = SettingsSyncPayload.seerrNotifications(SeerrNotificationSettingsPayload(
            updatedAt: Date(timeIntervalSince1970: 1), notifyPendingRequests: true))
        let stamped = original.restamped(Date(timeIntervalSince1970: 99))
        #expect(stamped.updatedAt == Date(timeIntervalSince1970: 99))
        guard case .seerrNotifications(let inner) = stamped else { Issue.record("wrong case"); return }
        #expect(inner.notifyPendingRequests == true)
    }
}
