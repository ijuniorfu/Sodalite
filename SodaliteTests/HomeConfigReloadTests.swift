import Testing
import Foundation
@testable import Sodalite

/// Home used to latch a config change into `needsReload` and consume it in `onAppear`. That works
/// when Settings is a tab (tvOS: leaving it re-appears Home), but on iOS Settings is a sheet over the
/// TabView, and a sheet dismiss fires no `onAppear` on the view underneath (measured on iOS 26), so
/// the flag stayed pending until the app was relaunched. Reloading is now scheduled directly and
/// coalesced, because Home Customize posts one notification per toggle.
@MainActor
struct HomeConfigReloadTests {
    final class MockLibraryService: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        /// loadContent() always starts with getLibraries, so this counts reloads.
        var getLibrariesCalls = 0

        func getLibraries(userID: String) async throws -> [JellyfinLibrary] {
            getLibrariesCalls += 1
            return []
        }

        struct Unused: Error {}
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            throw Unused()
        }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
            throw Unused()
        }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse {
            throw Unused()
        }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
            []
        }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private func makeViewModel(service: MockLibraryService) -> HomeViewModel {
        let vm = HomeViewModel(
            libraryService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1",
            serverID: "s1"
        )
        // Keep the coalescing window short so these tests stay fast.
        vm.configReloadDebounce = .milliseconds(30)
        return vm
    }

    /// Long enough for the debounce window plus the (service-stubbed) load to finish.
    private func waitForReload() async {
        try? await Task.sleep(for: .milliseconds(400))
    }

    @Test func configChangeTriggersAReloadWithoutAnyOnAppear() async {
        let service = MockLibraryService()
        let vm = makeViewModel(service: service)

        vm.scheduleConfigReload()
        await waitForReload()

        #expect(service.getLibrariesCalls == 1)
    }

    /// Home Customize posts one notification per toggle; flipping several rows must not fan out one
    /// full home reload per toggle.
    @Test func burstOfConfigChangesCoalescesIntoOneReload() async {
        let service = MockLibraryService()
        let vm = makeViewModel(service: service)

        for _ in 0..<5 {
            vm.scheduleConfigReload()
        }
        await waitForReload()

        #expect(service.getLibrariesCalls == 1)
    }

    /// A change arriving after the previous reload already ran must schedule a fresh one, not be
    /// swallowed as a duplicate.
    @Test func laterConfigChangeSchedulesAnotherReload() async {
        let service = MockLibraryService()
        let vm = makeViewModel(service: service)

        vm.scheduleConfigReload()
        await waitForReload()
        vm.scheduleConfigReload()
        await waitForReload()

        #expect(service.getLibrariesCalls == 2)
    }
}
