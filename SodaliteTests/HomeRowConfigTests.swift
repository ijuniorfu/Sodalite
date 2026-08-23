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
    /// a multi-library server, matching the reset-to-default baseline. Two libraries per type,
    /// because a type with a single library gets no per-library row at all
    /// (`PerLibraryRowRedundancyTests`).
    @Test func perLibraryRowsAreDisabledByDefault() {
        let libraries = [
            library("m1", "Movies A", "movies"),
            library("m2", "Movies B", "movies"),
            library("t1", "Shows A", "tvshows"),
            library("t2", "Shows B", "tvshows"),
        ]
        let fresh = HomeRowConfig.reconciled(stored: HomeRowConfig.defaultConfig(), libraries: libraries)

        let latestMovies = fresh.first { $0.type == .latestMovies }
        let latestShows = fresh.first { $0.type == .latestShows }
        #expect(latestMovies?.isEnabled == true)
        #expect(latestShows?.isEnabled == true)

        let perLibrary = fresh.filter { $0.type == .libraryLatest }
        #expect(perLibrary.count == 4)
        #expect(perLibrary.allSatisfy { !$0.isEnabled })
    }

    /// Vanished libraries drop their per-library row; surviving ones keep their user toggle. Three
    /// libraries of one type, so that removing one leaves two behind and the survivors keep earning
    /// their rows (with one left they would be retired as redundant instead).
    @Test func reconcileDropsVanishedLibraryRows() {
        let libraries = [
            library("m1", "Movies A", "movies"),
            library("m2", "Movies B", "movies"),
            library("m3", "Movies C", "movies"),
        ]
        var stored = HomeRowConfig.reconciled(stored: HomeRowConfig.defaultConfig(), libraries: libraries)
        // User enables one per-library row.
        if let idx = stored.firstIndex(where: { $0.type == .libraryLatest && $0.libraryID == "m1" }) {
            stored[idx].isEnabled = true
        }
        // One library is removed server-side.
        let after = HomeRowConfig.reconciled(stored: stored, libraries: Array(libraries.prefix(2)))
        let dynamic = after.filter { $0.type == .libraryLatest }
        #expect(dynamic.map(\.libraryID) == ["m1", "m2"])
        #expect(dynamic.first?.isEnabled == true)
    }

    /// A row type added in a later app version must reach users who already have a persisted
    /// config: reconciliation used to append only `.libraryLatest`, so a new static row was
    /// unreachable short of Reset to default.
    @Test func reconcileAppendsMissingStaticRowType() {
        var stored = HomeRowConfig.defaultConfig()
        stored.removeAll { $0.type == .topRatedMovies }
        #expect(!stored.contains { $0.type == .topRatedMovies })

        let after = HomeRowConfig.reconciled(stored: stored, libraries: [])

        let restored = after.first { $0.type == .topRatedMovies }
        #expect(restored != nil)
        #expect(restored?.isEnabled == HomeRowType.topRatedMovies.defaultEnabled)
    }

    /// The appended row must not disturb what the user configured: an off-by-default row they
    /// enabled stays enabled, and nobody's sortOrder shifts.
    @Test func reconcileAppendingPreservesExistingRowState() {
        var stored = HomeRowConfig.defaultConfig()
        stored.removeAll { $0.type == .topRatedMovies }
        if let idx = stored.firstIndex(where: { $0.type == .collections }) {
            stored[idx].isEnabled = true
        }
        if let idx = stored.firstIndex(where: { $0.type == .favorites }) {
            stored[idx].isEnabled = false
        }
        let before = stored

        let after = HomeRowConfig.reconciled(stored: stored, libraries: [])

        for old in before {
            let survivor = after.first { $0.id == old.id }
            #expect(survivor?.isEnabled == old.isEnabled)
            #expect(survivor?.sortOrder == old.sortOrder)
        }
        // Appended at the end, after the highest existing sortOrder.
        let appended = after.first { $0.type == .topRatedMovies }
        #expect((appended?.sortOrder ?? -1) > (before.map(\.sortOrder).max() ?? -1))
    }

    /// Reconciliation runs on every load; a second pass over its own output must be a no-op,
    /// else the persisted config churns and sortOrder drifts on each launch.
    @Test func reconcileIsIdempotentAfterAppending() {
        var stored = HomeRowConfig.defaultConfig()
        stored.removeAll { $0.type == .topRatedMovies }
        let libraries = [library("m1", "Movies", "movies")]

        let once = HomeRowConfig.reconciled(stored: stored, libraries: libraries)
        let twice = HomeRowConfig.reconciled(stored: once, libraries: libraries)
        #expect(once == twice)
    }
}
