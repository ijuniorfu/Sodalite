import Foundation
import Testing
@testable import Sodalite

@Suite("CloudSync merge rules")
struct CloudSyncMergeTests {
    private func user(_ id: String, addedAt: TimeInterval, token: String = "t") -> RememberedUser {
        RememberedUser(id: id, serverID: "s1", name: id, imageTag: nil, token: token, addedAt: Date(timeIntervalSince1970: addedAt))
    }

    private func serverPayload(users: [RememberedUser], password: String? = nil, passwordUserID: String? = nil,
                               homeRows: HomeRowsSyncState? = nil, at: TimeInterval) -> ServerSyncPayload {
        ServerSyncPayload(
            updatedAt: Date(timeIntervalSince1970: at),
            server: JellyfinServer(id: "s1", name: "Main", url: URL(string: "https://jf.example")!, version: nil),
            rememberedUsers: users, jellyfinPassword: password, passwordUserID: passwordUserID,
            seerrSessions: [], homeRows: homeRows)
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
}
