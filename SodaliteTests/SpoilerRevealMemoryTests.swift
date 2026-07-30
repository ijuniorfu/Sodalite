import Testing
import Foundation
@testable import Sodalite

/// Items the user manually revealed (Sodalite#50). Bounded like TrackSelectionMemory, and
/// eviction is harmless: an entry that old belongs to a title the policy reveals anyway.
@MainActor
struct SpoilerRevealMemoryTests {

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "SpoilerRevealMemoryTests.\(name)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test("a reveal is readable and lands in revealedKeys")
    func revealWritesThrough() {
        let memory = SpoilerRevealMemory(store: defaults("write"))
        memory.reveal("u1|i1")
        #expect(memory.isRevealed("u1|i1"))
        #expect(memory.revealedKeys == ["u1|i1"])
        #expect(!memory.isRevealed("u1|i2"))
    }

    @Test("reveals survive a new instance over the same defaults")
    func revealPersists() {
        let store = defaults("persist")
        SpoilerRevealMemory(store: store).reveal("u1|i1")
        #expect(SpoilerRevealMemory(store: store).isRevealed("u1|i1"))
    }

    @Test("the cap evicts the oldest reveal")
    func capEvictsOldest() {
        let memory = SpoilerRevealMemory(store: defaults("cap"))
        for i in 0...SpoilerRevealMemory.maxEntries {
            memory.reveal("u1|i\(i)", now: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(memory.entries.count == SpoilerRevealMemory.maxEntries)
        #expect(!memory.isRevealed("u1|i0"))
        #expect(memory.isRevealed("u1|i\(SpoilerRevealMemory.maxEntries)"))
    }

    @Test("replaceAll swaps the set and caps the incoming one")
    func replaceAllCaps() {
        let memory = SpoilerRevealMemory(store: defaults("replace"))
        memory.reveal("u1|old")
        var incoming: [String: Date] = [:]
        for i in 0..<(SpoilerRevealMemory.maxEntries + 10) {
            incoming["u1|n\(i)"] = Date(timeIntervalSince1970: Double(i))
        }
        memory.replaceAll(incoming)
        #expect(memory.entries.count == SpoilerRevealMemory.maxEntries)
        #expect(!memory.isRevealed("u1|old"))
        #expect(memory.revealedKeys.count == memory.entries.count)
    }
}
