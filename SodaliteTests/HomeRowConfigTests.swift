import Testing
import Foundation
@testable import Sodalite

/// A fresh install and the Customize "Reset to default" button must land on the same home page.
/// Both flows share `defaultConfig()`, but reconciliation used to apply an adaptive multi-library
/// default (aggregated Latest off, per-library rows on) that reset never reproduced, so the two
/// diverged on multi-library servers. These tests pin the parity contract.
@MainActor
struct HomeRowConfigTests {
    private func library(_ id: String, _ name: String, _ type: String) -> JellyfinLibrary {
        JellyfinLibrary(id: id, name: name, collectionType: type, imageTags: nil)
    }

    /// Reconciling the fresh-install default against a multi-library server must equal what
    /// "Reset to default" produces for the same discovered libraries.
    @Test func freshInstallMatchesResetOnMultiLibraryServer() {
        let libraries = [
            library("m1", "Movies A", "movies"),
            library("m2", "Movies B", "movies"),
            library("t1", "Shows", "tvshows"),
        ]
        let fresh = HomeRowConfig.reconciled(stored: HomeRowConfig.defaultConfig(), libraries: libraries)
        let reset = HomeRowConfig.resetToDefault(current: fresh)
        #expect(fresh == reset)
    }

    /// Single-library servers were already consistent; guard against regressing that.
    @Test func freshInstallMatchesResetOnSingleLibraryServer() {
        let libraries = [library("m1", "Movies", "movies")]
        let fresh = HomeRowConfig.reconciled(stored: HomeRowConfig.defaultConfig(), libraries: libraries)
        let reset = HomeRowConfig.resetToDefault(current: fresh)
        #expect(fresh == reset)
    }

    /// The aggregated Latest rows stay enabled and per-library rows stay opt-in (disabled) even on
    /// a multi-library server, matching the reset-to-default baseline.
    @Test func perLibraryRowsAreDisabledByDefault() {
        let libraries = [
            library("m1", "Movies A", "movies"),
            library("t1", "Shows", "tvshows"),
        ]
        let fresh = HomeRowConfig.reconciled(stored: HomeRowConfig.defaultConfig(), libraries: libraries)

        let latestMovies = fresh.first { $0.type == .latestMovies }
        let latestShows = fresh.first { $0.type == .latestShows }
        #expect(latestMovies?.isEnabled == true)
        #expect(latestShows?.isEnabled == true)

        let perLibrary = fresh.filter { $0.type == .libraryLatest }
        #expect(perLibrary.count == 2)
        #expect(perLibrary.allSatisfy { !$0.isEnabled })
    }

    /// Vanished libraries drop their per-library row; surviving ones keep their user toggle.
    @Test func reconcileDropsVanishedLibraryRows() {
        let libraries = [
            library("m1", "Movies A", "movies"),
            library("t1", "Shows", "tvshows"),
        ]
        var stored = HomeRowConfig.reconciled(stored: HomeRowConfig.defaultConfig(), libraries: libraries)
        // User enables one per-library row.
        if let idx = stored.firstIndex(where: { $0.type == .libraryLatest && $0.libraryID == "m1" }) {
            stored[idx].isEnabled = true
        }
        // The tvshows library is removed server-side.
        let after = HomeRowConfig.reconciled(stored: stored, libraries: [library("m1", "Movies A", "movies")])
        let dynamic = after.filter { $0.type == .libraryLatest }
        #expect(dynamic.count == 1)
        #expect(dynamic.first?.libraryID == "m1")
        #expect(dynamic.first?.isEnabled == true)
    }
}
