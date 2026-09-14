import Testing
import Foundation
@testable import Sodalite

/// Sodalite#117, DrHurt: Home kept showing the shelf it had loaded before the Apple TV went to
/// sleep, for any length of time, and only a force quit brought a fresh one.
///
/// The cause is a lifecycle event that does not exist. Measured with a throwaway SwiftUI app on
/// tvOS 26.5 and iOS 26.5: a background round trip delivers `scenePhase` transitions and nothing
/// else, no second `onAppear`, no `onDisappear`, no `.task` re-run. Home's only staleness gate hung
/// on `onAppear`, so a resumed app had no path to refresh at all.
///
/// The gate itself is what these pin. It now lives on the view model, because two triggers ask it
/// the same question (a return to the tab, a return of the app) and they must not drift apart.
@MainActor
struct HomeForegroundRefreshTests {

    /// Counts what the fan-out asks for, so "did it refetch" is an observation rather than a guess.
    final class CountingService: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        private(set) var resumeCalls = 0
        let resumeItems: [JellyfinItem]

        init(resumeItems: [JellyfinItem]) {
            self.resumeItems = resumeItems
        }

        struct Unused: Error {}

        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
            resumeCalls += 1
            return JellyfinItemsResponse(items: resumeItems, totalRecordCount: resumeItems.count)
        }

        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
            throw Unused()
        }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { throw Unused() }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { throw Unused() }
        func getGenres(userID: String) async throws -> [NamedItem] { throw Unused() }
        func getStudios(userID: String) async throws -> [NamedItem] { throw Unused() }
    }

    private func makeIdentity() -> CacheIdentity {
        CacheIdentity(serverID: "fg-\(UUID().uuidString)", userID: "u-\(UUID().uuidString)")
    }

    private func forget(_ identity: CacheIdentity) {
        FilterCache.shared.evict(identity: identity)
        UserDefaults.standard.removeObject(forKey: "homeRowConfigs.\(identity.serverID)")
    }

    private func makeViewModel(service: CountingService, identity: CacheIdentity) -> HomeViewModel {
        HomeViewModel(
            libraryService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: identity.userID,
            serverID: identity.serverID
        )
    }

    /// The reported case: the app was suspended for longer than the window and comes back. This is
    /// the only trigger a resumed app gets, so if the gate declines here, Home never refreshes.
    @Test("a shelf older than the refresh window is refetched")
    func staleShelfRefetches() async {
        let identity = makeIdentity()
        defer { forget(identity) }

        let service = CountingService(resumeItems: [JellyfinItem(seriesStub: "m1", name: "m1")])
        let viewModel = makeViewModel(service: service, identity: identity)
        await viewModel.loadContent()
        #expect(service.resumeCalls == 1, "precondition: the first load fetched")

        viewModel.lastLoadedAt = Date(
            timeIntervalSinceNow: -(HomeViewModel.refreshStaleSeconds + 1)
        )
        await viewModel.refreshIfStale()

        #expect(service.resumeCalls == 2, "a shelf older than the window was left stale")
    }

    /// The other half of the same gate: coming back to the app after a few seconds must not refetch
    /// the whole shelf. tvOS delivers an inactive/active pair for far less than a real background
    /// trip, and the app switcher alone would otherwise fan out every time.
    @Test("a shelf inside the refresh window is left alone")
    func freshShelfIsNotRefetched() async {
        let identity = makeIdentity()
        defer { forget(identity) }

        let service = CountingService(resumeItems: [JellyfinItem(seriesStub: "m1", name: "m1")])
        let viewModel = makeViewModel(service: service, identity: identity)
        await viewModel.loadContent()

        await viewModel.refreshIfStale()

        #expect(service.resumeCalls == 1, "a shelf loaded a moment ago was refetched")
    }

    /// Launch fires the same transition into `.active` as a return does, and it fires it while the
    /// first load is still in flight. A view model that has never completed a load is therefore
    /// deliberately not stale: otherwise every launch would fan out twice.
    @Test("a view model that never completed a load does not start a second one")
    func neverLoadedDoesNotRefetch() async {
        let identity = makeIdentity()
        defer { forget(identity) }

        let service = CountingService(resumeItems: [])
        let viewModel = makeViewModel(service: service, identity: identity)
        #expect(viewModel.lastLoadedAt == nil, "precondition: nothing has loaded yet")

        await viewModel.refreshIfStale()

        #expect(service.resumeCalls == 0, "the launch transition fanned out on top of the first load")
    }
}
