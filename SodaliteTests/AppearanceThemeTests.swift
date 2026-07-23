import Foundation
import Testing
@testable import Sodalite

@Suite("Appearance theme")
struct AppearanceThemeTests {
    @Test("catalog has three free and twenty supporter accents")
    func catalogMembership() {
        #expect(AccentPreset.allCases.filter { $0.tier == .free }.count == 3)
        #expect(AccentPreset.allCases.filter { $0.tier == .supporter }.count == 20)
        #expect(Set(AccentPreset.allCases.map(\.rawValue)).count == 23)
        for preset in AccentPreset.allCases {
            #expect(preset.category.presets.contains(preset))
        }
    }

    @Test("legacy raw identifiers resolve to approved presets", arguments: [
        ("system", AccentPreset.systemBlue),
        ("gold", .champagne),
        ("sunset", .apricot),
        ("rose", .blush),
        ("crimson", .ruby),
        ("ocean", .sky),
        ("mint", .mint),
        ("emerald", .emerald),
        ("amethyst", .royalViolet),
        ("lavender", .lavender)
    ])
    func legacyIdentifiers(raw: String, expected: AccentPreset) {
        #expect(AccentPreset(rawValue: raw) == expected)
    }

    @Test("role colors meet fixed reference contrast")
    func roleContrast() {
        let lightGlass = RGBColor(hex: 0xF2F2F7)
        let darkSurface = RGBColor(hex: 0x16181D)
        for preset in AccentPreset.allCases {
            #expect(preset.palette.navigation.contrastRatio(with: lightGlass) >= 4.5)
            #expect(preset.palette.focus.contrastRatio(with: darkSurface) >= 3.0)
        }
    }

    @Test("entitlement fallback is independent per axis")
    func entitlementResolution() {
        let free = AppearanceThemeResolver.resolve(
            storedAccent: .violet,
            storedBackground: .oledBlack,
            isSupporter: false
        )
        #expect(free.accent == .violet)
        #expect(free.background == .oledBlack)

        let premiumAccent = AppearanceThemeResolver.resolve(
            storedAccent: .ultraviolet,
            storedBackground: .oledBlack,
            isSupporter: false
        )
        #expect(premiumAccent.accent == .systemBlue)
        #expect(premiumAccent.background == .oledBlack)

        let premiumBackground = AppearanceThemeResolver.resolve(
            storedAccent: .orange,
            storedBackground: .polishedCrystal,
            isSupporter: false
        )
        #expect(premiumBackground.accent == .orange)
        #expect(premiumBackground.background == .graphiteGlass)

        let supporter = AppearanceThemeResolver.resolve(
            storedAccent: .ultraviolet,
            storedBackground: .polishedCrystal,
            isSupporter: true
        )
        #expect(supporter.accent == .ultraviolet)
        #expect(supporter.background == .polishedCrystal)
    }

    @Test("background defaults to graphite and persists")
    @MainActor
    func backgroundPreference() {
        let suite = "AppearanceThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppearancePreferences(store: defaults)
        #expect(first.backgroundStyle == .graphiteGlass)
        first.backgroundStyle = .cinemaNoir

        let second = AppearancePreferences(store: defaults)
        #expect(second.backgroundStyle == .cinemaNoir)
    }
}
