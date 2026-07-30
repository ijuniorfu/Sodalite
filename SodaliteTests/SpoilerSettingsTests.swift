import Testing
import Foundation
@testable import Sodalite

/// The three opt-in switches behind Sodalite#50. Protection is off by default; when it is on,
/// episodes are covered and movies are not, because an episode synopsis is the reported problem.
@MainActor
struct SpoilerSettingsTests {

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "SpoilerSettingsTests.\(name)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test("protection is off by default, episodes on, movies off")
    func defaultValues() {
        let prefs = AppearancePreferences(store: defaults("defaults"))
        #expect(prefs.spoilerProtectionEnabled == false)
        #expect(prefs.spoilerHideEpisodes == true)
        #expect(prefs.spoilerHideMovies == false)
    }

    @Test("all three write through to the store")
    func writeThrough() {
        let store = defaults("persist")
        let prefs = AppearancePreferences(store: store)
        prefs.spoilerProtectionEnabled = true
        prefs.spoilerHideEpisodes = false
        prefs.spoilerHideMovies = true

        let reloaded = AppearancePreferences(store: store)
        #expect(reloaded.spoilerProtectionEnabled == true)
        #expect(reloaded.spoilerHideEpisodes == false)
        #expect(reloaded.spoilerHideMovies == true)
    }

    @Test("the three rows are wired into the appearance toggles section")
    func rowsPresent() throws {
        let source = try sourceFile("Sodalite/Features/Support/AppearanceSettingsView.swift")
        #expect(source.contains("settings.appearance.spoiler"))
        #expect(source.contains("settings.appearance.spoilerEpisodes"))
        #expect(source.contains("settings.appearance.spoilerMovies"))
        #expect(source.contains("appearance.spoilerProtectionEnabled"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
