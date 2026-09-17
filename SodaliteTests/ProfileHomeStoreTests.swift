import Foundation
import Testing
@testable import Sodalite

@Suite("Profile home store", .serialized)
@MainActor
struct ProfileHomeStoreTests {
    @Test func aProfileScopeAndItsServerScopeAreSeparate() {
        let server = "home-\(UUID().uuidString)"
        let profile = ProfileKey(serverID: server, userID: "alice").storageScope

        HomeRowConfig.setMergeContinueWatchingNextUp(true, scope: profile)

        #expect(HomeRowConfig.mergeContinueWatchingNextUp(scope: profile))
        #expect(!HomeRowConfig.mergeContinueWatchingNextUp(scope: server))
    }

    @Test func copyCarriesEveryHomeValue() {
        let server = "home-\(UUID().uuidString)"
        let target = ProfileKey(serverID: server, userID: "bob").storageScope
        HomeRowConfig.setMergeContinueWatchingNextUp(true, scope: server)
        HomeRowConfig.setEnableRewatchingNextUp(true, scope: server)
        HomeRowConfig.setCollectionGrouping(.never, scope: server)
        HomeRowConfig.saveToStorage(Array(HomeRowConfig.defaultConfig().reversed()), scope: server)
        LibrarySortStore.setSort(LibrarySort(key: .dateAdded, descending: true), scope: .library(id: "movies", scope: server))

        ProfileHomeStore.copy(fromScope: server, toScope: target)

        #expect(ProfileHomeStore.collect(scope: target, stamp: .distantPast)
                == ProfileHomeStore.collect(scope: server, stamp: .distantPast))
        #expect(LibrarySortStore.sort(.library(id: "movies", scope: target)) == LibrarySort(key: .dateAdded, descending: true))
    }

    @Test func profileKeyFollowsTheCacheIdentityFallback() {
        let state = AppState()
        #expect(state.profileKey == nil)
        state.setAuthenticated(
            server: JellyfinServer(id: "srv", name: "Main", url: URL(string: "https://jf.example")!, version: "10.10"),
            user: JellyfinUser(id: "u1", name: "vincent", serverID: "srv", hasPassword: true, primaryImageTag: nil, policy: nil)
        )
        #expect(state.profileKey == ProfileKey(serverID: "srv", userID: "u1"))
    }
}
