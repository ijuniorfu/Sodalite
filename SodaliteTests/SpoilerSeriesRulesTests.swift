import Testing
import Foundation
@testable import Sodalite

/// Per-series spoiler rules (Sodalite#50 follow-up). Tri-state, because "standard" has to travel
/// as a tombstone: deleting the key would let the other device's copy resurrect it.
@MainActor
struct SpoilerSeriesRulesTests {

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "SpoilerSeriesRulesTests.\(name)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test("a rule is readable and lands in overrides")
    func setWritesThrough() {
        let rules = SpoilerSeriesRules(store: defaults("write"))
        rules.set(.hidden, for: "u1|s1")
        rules.set(.shown, for: "u1|s2")
        #expect(rules.rule(for: "u1|s1") == .hidden)
        #expect(rules.rule(for: "u1|s2") == .shown)
        #expect(rules.overrides == ["u1|s1": true, "u1|s2": false])
    }

    @Test("an unknown series is standard and carries no override")
    func unknownIsStandard() {
        let rules = SpoilerSeriesRules(store: defaults("unknown"))
        #expect(rules.rule(for: "u1|s1") == .standard)
        #expect(rules.overrides.isEmpty)
    }

    @Test("standard is stored as a tombstone but is no override")
    func standardIsATombstone() {
        let rules = SpoilerSeriesRules(store: defaults("tombstone"))
        rules.set(.hidden, for: "u1|s1")
        rules.set(.standard, for: "u1|s1")
        #expect(rules.entries["u1|s1"]?.rule == .standard)
        #expect(rules.overrides["u1|s1"] == nil)
        #expect(rules.rule(for: "u1|s1") == .standard)
    }

    @Test("rules survive a new instance over the same defaults")
    func rulesPersist() {
        let store = defaults("persist")
        SpoilerSeriesRules(store: store).set(.shown, for: "u1|s1")
        #expect(SpoilerSeriesRules(store: store).rule(for: "u1|s1") == .shown)
    }

    @Test("setting a rule again moves its stamp")
    func setMovesStamp() {
        let rules = SpoilerSeriesRules(store: defaults("stamp"))
        rules.set(.hidden, for: "u1|s1", now: Date(timeIntervalSince1970: 1))
        rules.set(.shown, for: "u1|s1", now: Date(timeIntervalSince1970: 2))
        #expect(rules.entries["u1|s1"]?.updatedAt == Date(timeIntervalSince1970: 2))
    }

    @Test("the cap evicts the oldest rule")
    func capEvictsOldest() {
        let rules = SpoilerSeriesRules(store: defaults("cap"))
        for i in 0...SpoilerSeriesRules.maxEntries {
            rules.set(.hidden, for: "u1|s\(i)", now: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(rules.entries.count == SpoilerSeriesRules.maxEntries)
        #expect(rules.rule(for: "u1|s0") == .standard)
    }

    @Test("replaceAll swaps the whole set and re-derives overrides")
    func replaceAllSwaps() {
        let rules = SpoilerSeriesRules(store: defaults("replace"))
        rules.set(.hidden, for: "u1|s1")
        rules.replaceAll(["u1|s2": SpoilerSeriesRuleEntry(rule: .shown, updatedAt: Date())])
        #expect(rules.rule(for: "u1|s1") == .standard)
        #expect(rules.overrides == ["u1|s2": false])
    }
}
