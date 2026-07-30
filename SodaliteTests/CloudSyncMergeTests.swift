import Foundation
import Testing
@testable import Sodalite

@Suite("CloudSync merge rules")
struct CloudSyncMergeTests {
    private func user(_ id: String, addedAt: TimeInterval, token: String = "t") -> RememberedUser {
        RememberedUser(id: id, serverID: "s1", name: id, imageTag: nil, token: token, addedAt: Date(timeIntervalSince1970: addedAt))
    }

    private func serverPayload(users: [RememberedUser], password: String? = nil, passwordUserID: String? = nil,
                               homeRows: HomeRowsSyncState? = nil, defaultUserID: String? = nil,
                               at: TimeInterval) -> ServerSyncPayload {
        ServerSyncPayload(
            updatedAt: Date(timeIntervalSince1970: at),
            server: JellyfinServer(id: "s1", name: "Main", url: URL(string: "https://jf.example")!, version: nil),
            rememberedUsers: users, jellyfinPassword: password, passwordUserID: passwordUserID,
            seerrSessions: [], homeRows: homeRows, defaultUserID: defaultUserID)
    }

    @Test("monotonic stamp uses now when ahead of highest seen")
    func stampNowWins() {
        let now = Date(timeIntervalSince1970: 100)
        #expect(CloudSyncMerge.monotonicStamp(now: now, highestSeen: Date(timeIntervalSince1970: 50)) == now)
        #expect(CloudSyncMerge.monotonicStamp(now: now, highestSeen: nil) == now)
    }

    @Test("monotonic stamp bumps past a skewed-ahead remote stamp")
    func stampBumpsPastSkew() {
        let now = Date(timeIntervalSince1970: 100)
        let seen = Date(timeIntervalSince1970: 200)
        let stamp = CloudSyncMerge.monotonicStamp(now: now, highestSeen: seen)
        #expect(stamp > seen)
        #expect(stamp.timeIntervalSince(seen) < 0.01)
    }

    @Test("LWW: remote wins only when strictly newer")
    func lww() {
        let older = Date(timeIntervalSince1970: 1)
        let newer = Date(timeIntervalSince1970: 2)
        #expect(CloudSyncMerge.remoteWins(localUpdatedAt: older, remoteUpdatedAt: newer))
        #expect(!CloudSyncMerge.remoteWins(localUpdatedAt: newer, remoteUpdatedAt: older))
        #expect(!CloudSyncMerge.remoteWins(localUpdatedAt: newer, remoteUpdatedAt: newer))
    }

    @Test("remembered users union by id, newer addedAt wins")
    func userUnion() {
        let merged = CloudSyncMerge.unionRememberedUsers(
            local: [user("a", addedAt: 10, token: "localA"), user("b", addedAt: 5)],
            cloud: [user("a", addedAt: 20, token: "cloudA"), user("c", addedAt: 1)])
        #expect(merged.count == 3)
        #expect(merged.first(where: { $0.id == "a" })?.token == "cloudA")
        #expect(merged.map(\.id) == ["a", "b", "c"]) // sorted by addedAt descending
    }

    @Test("adoption: cloud wins server fields, users union, local-only extras survive")
    func adoption() {
        let local = serverPayload(users: [user("onlyLocal", addedAt: 30)], password: "localPW", passwordUserID: "onlyLocal",
                                  homeRows: HomeRowsSyncState(configsJSON: nil, mergeCWNextUp: true, rewatchNextUp: true), at: 999)
        let cloud = serverPayload(users: [user("onlyCloud", addedAt: 10)], at: 5)
        let stamp = Date(timeIntervalSince1970: 1000)
        let merged = CloudSyncMerge.adoptServerPayload(local: local, cloud: cloud, stamp: stamp)
        #expect(merged.updatedAt == stamp)
        #expect(Set(merged.rememberedUsers.map(\.id)) == ["onlyLocal", "onlyCloud"])
        // Cloud has no password, so the local one survives adoption.
        #expect(merged.jellyfinPassword == "localPW")
        #expect(merged.passwordUserID == "onlyLocal")
        // Cloud has no home rows, so local rows survive.
        #expect(merged.homeRows?.mergeCWNextUp == true)
    }

    // A cloud payload written before the default-profile pin moved into the server record carries no
    // pin; adoption must keep the local one instead of clearing it.
    @Test("adoption: local default-profile pin survives a cloud payload without one")
    func adoptionKeepsLocalDefaultUserID() {
        let local = serverPayload(users: [], defaultUserID: "u1", at: 999)
        let cloud = serverPayload(users: [], at: 5)
        let merged = CloudSyncMerge.adoptServerPayload(local: local, cloud: cloud, stamp: Date(timeIntervalSince1970: 1000))
        #expect(merged.defaultUserID == "u1")
    }

    @Test("adoption: cloud default-profile pin wins when present")
    func adoptionCloudDefaultUserIDWins() {
        let local = serverPayload(users: [], defaultUserID: "u1", at: 999)
        let cloud = serverPayload(users: [], defaultUserID: "u2", at: 5)
        let merged = CloudSyncMerge.adoptServerPayload(local: local, cloud: cloud, stamp: Date(timeIntervalSince1970: 1000))
        #expect(merged.defaultUserID == "u2")
    }

    @Test("adoption: cloud password and home rows win when present")
    func adoptionCloudWins() {
        let local = serverPayload(users: [], password: "localPW", passwordUserID: "u1",
                                  homeRows: HomeRowsSyncState(configsJSON: nil, mergeCWNextUp: true, rewatchNextUp: false), at: 999)
        var cloud = serverPayload(users: [], password: "cloudPW", passwordUserID: "u2", at: 5)
        cloud.homeRows = HomeRowsSyncState(configsJSON: Data("[]".utf8), mergeCWNextUp: false, rewatchNextUp: true)
        let merged = CloudSyncMerge.adoptServerPayload(local: local, cloud: cloud, stamp: Date(timeIntervalSince1970: 1000))
        #expect(merged.jellyfinPassword == "cloudPW")
        #expect(merged.passwordUserID == "u2")
        #expect(merged.homeRows?.mergeCWNextUp == false)
    }

    @Test("seerr sessions union by user id, cloud wins collisions")
    func seerrUnion() {
        func session(_ userID: String, cookie: String) -> RememberedSeerrSession {
            RememberedSeerrSession(jellyfinUserID: userID, jellyfinServerID: "s1",
                                   seerrServer: SeerrServer(id: "se", url: URL(string: "https://se.example")!), cookie: cookie)
        }
        let merged = CloudSyncMerge.unionSeerrSessions(
            local: [session("a", cookie: "localA"), session("b", cookie: "localB")],
            cloud: [session("a", cookie: "cloudA")])
        #expect(merged.count == 2)
        #expect(merged.first(where: { $0.jellyfinUserID == "a" })?.cookie == "cloudA")
        #expect(merged.first(where: { $0.jellyfinUserID == "b" })?.cookie == "localB")
    }

    // MARK: - Track memory union (Sodalite#46)

    private func memoryEntry(_ seconds: TimeInterval, off: Bool) -> TrackMemoryEntry {
        TrackMemoryEntry(subtitle: off ? .off : nil, audio: nil,
                         updatedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test("disjoint track memories union instead of replacing each other")
    func trackMemoryUnionIsDisjointSafe() {
        let local = TrackMemoryPayload(updatedAt: Date(timeIntervalSince1970: 5),
                                       entries: ["a": memoryEntry(5, off: true)])
        let cloud = TrackMemoryPayload(updatedAt: Date(timeIntervalSince1970: 7),
                                       entries: ["b": memoryEntry(7, off: true)])
        let merged = CloudSyncMerge.unionTrackMemory(local: local, cloud: cloud)
        #expect(Set(merged.entries.keys) == ["a", "b"])
        #expect(merged.updatedAt == Date(timeIntervalSince1970: 7))
    }

    @Test("a colliding key resolves to the newer entry")
    func trackMemoryUnionPrefersNewerEntry() {
        let local = TrackMemoryPayload(updatedAt: Date(timeIntervalSince1970: 9),
                                       entries: ["a": memoryEntry(9, off: true)])
        let cloud = TrackMemoryPayload(updatedAt: Date(timeIntervalSince1970: 3),
                                       entries: ["a": memoryEntry(3, off: false)])
        #expect(CloudSyncMerge.unionTrackMemory(local: local, cloud: cloud).entries["a"]?.subtitle == .off)
    }

    @Test("the union is capped so both devices converge on the same set")
    func trackMemoryUnionCaps() {
        var localEntries: [String: TrackMemoryEntry] = [:]
        var cloudEntries: [String: TrackMemoryEntry] = [:]
        for i in 0..<TrackSelectionMemory.maxEntries {
            localEntries["l\(i)"] = memoryEntry(Double(i), off: true)
            cloudEntries["c\(i)"] = memoryEntry(Double(i) + 0.5, off: true)
        }
        let merged = CloudSyncMerge.unionTrackMemory(
            local: TrackMemoryPayload(updatedAt: Date(timeIntervalSince1970: 1), entries: localEntries),
            cloud: TrackMemoryPayload(updatedAt: Date(timeIntervalSince1970: 1), entries: cloudEntries))
        #expect(merged.entries.count == TrackSelectionMemory.maxEntries)
        #expect(merged.entries["l0"] == nil)
    }

    // MARK: Spoiler reveals (Sodalite#50)

    @Test("disjoint spoiler reveals union instead of replacing each other")
    func spoilerRevealUnionIsDisjointSafe() {
        let local = SpoilerRevealPayload(updatedAt: Date(timeIntervalSince1970: 5),
                                         entries: ["u1|a": Date(timeIntervalSince1970: 5)])
        let cloud = SpoilerRevealPayload(updatedAt: Date(timeIntervalSince1970: 7),
                                         entries: ["u1|b": Date(timeIntervalSince1970: 7)])
        let merged = CloudSyncMerge.unionSpoilerReveals(local: local, cloud: cloud)
        #expect(Set(merged.entries.keys) == ["u1|a", "u1|b"])
        #expect(merged.updatedAt == Date(timeIntervalSince1970: 7))
    }

    @Test("a colliding spoiler key keeps the later reveal")
    func spoilerRevealUnionPrefersNewer() {
        let local = SpoilerRevealPayload(updatedAt: Date(timeIntervalSince1970: 9),
                                         entries: ["u1|a": Date(timeIntervalSince1970: 9)])
        let cloud = SpoilerRevealPayload(updatedAt: Date(timeIntervalSince1970: 3),
                                         entries: ["u1|a": Date(timeIntervalSince1970: 3)])
        #expect(CloudSyncMerge.unionSpoilerReveals(local: local, cloud: cloud).entries["u1|a"]
                == Date(timeIntervalSince1970: 9))
    }

    @Test("the spoiler union is capped so both devices converge")
    func spoilerRevealUnionCaps() {
        var localEntries: [String: Date] = [:]
        var cloudEntries: [String: Date] = [:]
        for i in 0..<SpoilerRevealMemory.maxEntries {
            localEntries["l\(i)"] = Date(timeIntervalSince1970: Double(i))
            cloudEntries["c\(i)"] = Date(timeIntervalSince1970: Double(i) + 0.5)
        }
        let merged = CloudSyncMerge.unionSpoilerReveals(
            local: SpoilerRevealPayload(updatedAt: Date(timeIntervalSince1970: 1), entries: localEntries),
            cloud: SpoilerRevealPayload(updatedAt: Date(timeIntervalSince1970: 1), entries: cloudEntries))
        #expect(merged.entries.count == SpoilerRevealMemory.maxEntries)
        #expect(merged.entries["l0"] == nil)
    }

    @Test("an appearance payload without the spoiler keys decodes to the defaults")
    func appearancePayloadBackCompat() throws {
        let legacy = #"""
        {"schemaVersion":2,"updatedAt":0,"accentChoice":"systemBlue","backgroundStyle":"graphiteGlass",
         "showContentLogos":true,"continueWatchingImage":"still","largeCards":false,
         "nowPlayingUsesSeriesPoster":false}
        """#
        let payload = try JSONDecoder().decode(AppearanceSettingsPayload.self, from: Data(legacy.utf8))
        #expect(payload.spoilerProtectionEnabled == false)
        #expect(payload.spoilerHideEpisodes == true)
        #expect(payload.spoilerHideMovies == false)
    }
}
