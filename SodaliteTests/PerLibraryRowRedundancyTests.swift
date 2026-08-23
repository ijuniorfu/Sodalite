import Testing
import Foundation
@testable import Sodalite

/// A per-library "Latest in X" row splits one library out of the aggregated Latest row. With only
/// one library of that type there is nothing to split: the two rows run the same query and render
/// the same tiles under two names (device report, 2026-08-23). So the per-library row exists only
/// where the type has more than one library, and a row that loses its reason to exist hands its
/// enabled state back to the aggregated row rather than taking a shelf away.
@MainActor
struct PerLibraryRowRedundancyTests {
    private func library(_ id: String, _ name: String, _ type: String) -> JellyfinLibrary {
        JellyfinLibrary(id: id, name: name, collectionType: type, imageTags: nil)
    }

    private func perLibraryRow(_ id: String, _ type: String, isEnabled: Bool) -> HomeRowConfig {
        HomeRowConfig(
            type: .libraryLatest,
            isEnabled: isEnabled,
            sortOrder: 99,
            libraryID: id,
            libraryName: id,
            collectionType: type
        )
    }

    private func rows(_ configs: [HomeRowConfig], _ type: HomeRowType) -> [HomeRowConfig] {
        configs.filter { $0.type == type }
    }

    @Test func singleLibraryOfATypeGetsNoRowOfItsOwn() {
        let libraries = [library("m1", "Filme", "movies"), library("t1", "Serien", "tvshows")]
        let config = HomeRowConfig.reconciled(stored: HomeRowConfig.defaultConfig(), libraries: libraries)
        #expect(rows(config, .libraryLatest).isEmpty)
    }

    @Test func severalLibrariesOfATypeKeepTheirRows() {
        let libraries = [
            library("m1", "Movies A", "movies"),
            library("m2", "Movies B", "movies"),
            library("t1", "Serien", "tvshows"),
        ]
        let config = HomeRowConfig.reconciled(stored: HomeRowConfig.defaultConfig(), libraries: libraries)
        #expect(rows(config, .libraryLatest).map(\.libraryID) == ["m1", "m2"])
    }

    /// The user switched this row on and may have switched the aggregated one off in its favour.
    /// Dropping the row silently would leave them with no movie shelf at all.
    @Test func anEnabledRowThatBecomesRedundantTurnsTheAggregateOn() {
        var stored = HomeRowConfig.defaultConfig()
        stored[stored.firstIndex { $0.type == .latestMovies }!].isEnabled = false
        stored.append(perLibraryRow("m1", "movies", isEnabled: true))

        let config = HomeRowConfig.reconciled(stored: stored, libraries: [library("m1", "Filme", "movies")])

        #expect(rows(config, .libraryLatest).isEmpty)
        #expect(rows(config, .latestMovies).first?.isEnabled == true)
    }

    @Test func aRedundantRowTheUserNeverEnabledLeavesTheAggregateAlone() {
        var stored = HomeRowConfig.defaultConfig()
        stored[stored.firstIndex { $0.type == .latestMovies }!].isEnabled = false
        stored.append(perLibraryRow("m1", "movies", isEnabled: false))

        let config = HomeRowConfig.reconciled(stored: stored, libraries: [library("m1", "Filme", "movies")])

        #expect(rows(config, .libraryLatest).isEmpty)
        #expect(rows(config, .latestMovies).first?.isEnabled == false)
    }

    @Test func theLibraryTypeDecidesWhichAggregateTurnsOn() {
        var stored = HomeRowConfig.defaultConfig()
        stored[stored.firstIndex { $0.type == .latestMovies }!].isEnabled = false
        stored[stored.firstIndex { $0.type == .latestShows }!].isEnabled = false
        stored.append(perLibraryRow("t1", "tvshows", isEnabled: true))

        let config = HomeRowConfig.reconciled(stored: stored, libraries: [library("t1", "Serien", "tvshows")])

        #expect(rows(config, .latestShows).first?.isEnabled == true)
        #expect(rows(config, .latestMovies).first?.isEnabled == false)
    }

    /// Two libraries justified both rows; once one library is gone the survivor is redundant too.
    @Test func losingTheSecondLibraryRetiresTheSurvivingRow() {
        var stored = HomeRowConfig.defaultConfig()
        stored[stored.firstIndex { $0.type == .latestMovies }!].isEnabled = false
        stored.append(perLibraryRow("m1", "movies", isEnabled: true))
        stored.append(perLibraryRow("m2", "movies", isEnabled: false))

        let config = HomeRowConfig.reconciled(stored: stored, libraries: [library("m1", "Movies A", "movies")])

        #expect(rows(config, .libraryLatest).isEmpty)
        #expect(rows(config, .latestMovies).first?.isEnabled == true)
    }

    /// Reconciliation runs on every load, so handing the state over must not repeat: a second pass
    /// finds nothing left to retire and must change nothing.
    @Test func retiringARowIsIdempotent() {
        var stored = HomeRowConfig.defaultConfig()
        stored[stored.firstIndex { $0.type == .latestMovies }!].isEnabled = false
        stored.append(perLibraryRow("m1", "movies", isEnabled: true))
        let libraries = [library("m1", "Filme", "movies")]

        let once = HomeRowConfig.reconciled(stored: stored, libraries: libraries)
        let twice = HomeRowConfig.reconciled(stored: once, libraries: libraries)
        #expect(once == twice)
    }
}
