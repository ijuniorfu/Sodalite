import Foundation
import Observation

/// Sodalite#50. Items the user manually revealed. Device-local (UserDefaults), mirrored to
/// CloudKit by a union merge over `entries`; read/write via `DependencyContainer.spoilerRevealMemory`.
@Observable
@MainActor
final class SpoilerRevealMemory {

    /// Bounded like `TrackSelectionMemory`. Eviction is harmless here: an entry that old belongs
    /// to a title the user has long since played, which the policy reveals anyway.
    nonisolated static let maxEntries = 500

    private static let storageKey = "spoiler.revealed"

    /// Reveal key ("<userID>|<itemID>") to reveal time. The cloud sync layer observes this, so
    /// every mutation replaces the dictionary rather than mutating it in place.
    private(set) var entries: [String: Date]

    /// Kept in step with `entries` instead of computed: the policy reads it once per card body,
    /// and `Set(entries.keys)` would allocate there on every frame.
    private(set) var revealedKeys: Set<String>

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        let loaded: [String: Date]
        if let data = store.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            loaded = decoded
        } else {
            loaded = [:]
        }
        self.entries = loaded
        self.revealedKeys = Set(loaded.keys)
    }

    func isRevealed(_ key: String) -> Bool { revealedKeys.contains(key) }

    func reveal(_ key: String, now: Date = Date()) {
        var updated = entries
        updated[key] = now
        apply(Self.capped(updated))
    }

    /// Cloud apply path: the merged set replaces the local one wholesale.
    func replaceAll(_ incoming: [String: Date]) {
        apply(Self.capped(incoming))
    }

    /// nonisolated: a pure function over its argument, and the cloud merge needs it.
    nonisolated static func capped(_ entries: [String: Date]) -> [String: Date] {
        guard entries.count > maxEntries else { return entries }
        let kept = entries
            .sorted { $0.value > $1.value }
            .prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private func apply(_ updated: [String: Date]) {
        entries = updated
        revealedKeys = Set(updated.keys)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        store.set(data, forKey: Self.storageKey)
    }
}
