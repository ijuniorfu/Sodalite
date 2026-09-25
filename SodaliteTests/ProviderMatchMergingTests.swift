import Testing
import Foundation
@testable import Sodalite

/// The two-phase merge contract is shared by the live grid and the precompute pass that writes FilterCache, so they cannot silently drift.
@MainActor
struct ProviderMatchMergingTests {
    private func item(_ id: String, _ name: String) -> JellyfinItem {
        JellyfinItem(seriesStub: id, name: name)
    }

    @Test func keepsPhase1OrderThenAppendsDedupedSortedExtras() {
        let phase1 = [item("1", "Zebra"), item("2", "Apple")]
        let phase2 = [item("2", "Apple"), item("3", "Mango"), item("4", "Banana")]
        let merged = ProviderMatchMerging.merge(phase1: phase1, phase2: phase2)
        // phase1 order preserved; id 2 deduped out of phase2; remaining extras sorted by name.
        #expect(merged.map(\.id) == ["1", "2", "4", "3"])
    }

    @Test func emptyPhase2YieldsPhase1Unchanged() {
        let phase1 = [item("1", "One"), item("2", "Two")]
        let merged = ProviderMatchMerging.merge(phase1: phase1, phase2: [])
        #expect(merged.map(\.id) == ["1", "2"])
    }

    @Test func allDuplicatesYieldNoExtras() {
        let phase1 = [item("1", "One")]
        let merged = ProviderMatchMerging.merge(phase1: phase1, phase2: [item("1", "One")])
        #expect(merged.map(\.id) == ["1"])
    }

    /// Audit 2026-09-25 BROWSE-5. TMDB reuses numeric ids per type; the tmdbMap both call sites
    /// build used to key on the bare Int, so a library movie and an unrelated show sharing a TMDB id
    /// collided.
    @Test func tmdbKeyDistinguishesMovieFromTVWithTheSameID() {
        #expect(ProviderMatchMerging.tmdbKey(type: .movie, tmdbID: 550) == "movie-550")
        #expect(ProviderMatchMerging.tmdbKey(type: .series, tmdbID: 550) == "tv-550")
        #expect(
            ProviderMatchMerging.tmdbKey(type: .movie, tmdbID: 550)
                != ProviderMatchMerging.tmdbKey(type: .series, tmdbID: 550)
        )
    }

    private func item(id: String, type: String, tmdbID: String) throws -> JellyfinItem {
        let json = "{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"\(type)\","
            + "\"ProviderIds\":{\"Tmdb\":\"\(tmdbID)\"}}"
        return try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    /// The exact collision the finding traced: a movie and a series sharing a TMDB id used to
    /// overwrite each other in the map the provider match (and FilteredGridView's own build)
    /// resolves phase 2 against, hiding one of the two library items entirely.
    @Test("a movie and a series sharing a TMDB id no longer overwrite each other in the tmdbMap build")
    func tmdbMapDoesNotCollideAcrossTypes() throws {
        let movie = try item(id: "m1", type: "Movie", tmdbID: "550")
        let show = try item(id: "s1", type: "Series", tmdbID: "550")

        var tmdbMap: [String: JellyfinItem] = [:]
        for candidate in [movie, show] {
            if let tmdbID = candidate.tmdbID {
                tmdbMap[ProviderMatchMerging.tmdbKey(type: candidate.type, tmdbID: tmdbID)] = candidate
            }
        }

        #expect(tmdbMap.count == 2, "the movie and the series overwrote each other under one bare-Int key")
        #expect(tmdbMap[ProviderMatchMerging.tmdbKey(type: .movie, tmdbID: 550)]?.id == "m1")
        #expect(tmdbMap[ProviderMatchMerging.tmdbKey(type: .series, tmdbID: 550)]?.id == "s1")
    }
}
