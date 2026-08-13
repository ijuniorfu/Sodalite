import Foundation
import Observation

/// Sodalite#50 follow-up. Per-series spoiler rules, keyed "<userID>|<seriesID>".
enum SpoilerSeriesRule: String, Codable, Sendable, CaseIterable {
    /// Veil this show's episodes and seasons whatever the global switches say.
    case hidden
    /// Never veil them, same caveat.
    case shown
    /// Follow the global switches. Stored rather than represented by a missing key: the cloud
    /// merge is last-writer-wins per key, so a deleted key would come back from the other device.
    case standard
}

struct SpoilerSeriesRuleEntry: Codable, Equatable, Sendable {
    var rule: SpoilerSeriesRule
    var updatedAt: Date
}

/// Device-local (UserDefaults), mirrored to CloudKit by a per-key last-writer-wins merge;
/// read/write via `DependencyContainer.spoilerSeriesRules`.
@Observable
@MainActor
final class SpoilerSeriesRules {

    /// Bounded like `SpoilerRevealMemory`. Evicting a tombstone can let an older `hidden` back in
    /// from the cloud; 500 shows is far past what anyone rules on by hand.
    nonisolated static let maxEntries = 500

    private static let storageKey = "spoiler.seriesRules"

    /// The cloud sync layer observes this, so every mutation replaces the dictionary.
    private(set) var entries: [String: SpoilerSeriesRuleEntry]

    /// Real overrides only, tombstones dropped. Kept in step with `entries` instead of computed:
    /// the policy reads it once per card body.
    private(set) var overrides: [String: Bool]

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        let loaded: [String: SpoilerSeriesRuleEntry]
        if let data = store.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: SpoilerSeriesRuleEntry].self, from: data) {
            loaded = decoded
        } else {
            loaded = [:]
        }
        self.entries = loaded
        self.overrides = Self.overrides(from: loaded)
    }

    func rule(for key: String) -> SpoilerSeriesRule {
        entries[key]?.rule ?? .standard
    }

    func set(_ rule: SpoilerSeriesRule, for key: String, now: Date = Date()) {
        var updated = entries
        updated[key] = SpoilerSeriesRuleEntry(rule: rule, updatedAt: now)
        apply(Self.capped(updated))
    }

    /// Cloud apply path: the merged set replaces the local one wholesale.
    func replaceAll(_ incoming: [String: SpoilerSeriesRuleEntry]) {
        apply(Self.capped(incoming))
    }

    /// nonisolated: pure functions over their argument, and the cloud merge needs the first one.
    nonisolated static func capped(_ entries: [String: SpoilerSeriesRuleEntry]) -> [String: SpoilerSeriesRuleEntry] {
        guard entries.count > maxEntries else { return entries }
        let kept = entries
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    nonisolated static func overrides(from entries: [String: SpoilerSeriesRuleEntry]) -> [String: Bool] {
        entries.reduce(into: [:]) { result, pair in
            switch pair.value.rule {
            case .hidden: result[pair.key] = true
            case .shown: result[pair.key] = false
            case .standard: break
            }
        }
    }

    private func apply(_ updated: [String: SpoilerSeriesRuleEntry]) {
        entries = updated
        overrides = Self.overrides(from: updated)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        store.set(data, forKey: Self.storageKey)
    }
}
