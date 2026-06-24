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
}
