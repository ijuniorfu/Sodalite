import Foundation

/// The app's accent colour, mirrored into the shared container so the extension can draw the
/// resume bar in it. Only the resolved RGB value crosses over, never `AccentPreset`: the preset
/// table lives in AppearanceTheme.swift and pulling it into the extension would mean a second
/// copy of 23 colours to keep in sync, plus a SwiftUI import the extension has no use for.
///
/// `nonisolated` for the same reason as `TopShelfProgress`: the app targets default to MainActor
/// isolation, the extension defaults to nonisolated, and both compile this file.
enum TopShelfAccent {
    nonisolated static let defaultsKey = "topshelf.accentHex"

    /// systemBlue, matching AccentPreset.systemBlue's control colour. Used before the app has
    /// ever written a value, which is every install that predates this feature.
    nonisolated static let fallback: UInt32 = 0x007AFF

    nonisolated static func read() -> UInt32 {
        guard let defaults = UserDefaults(suiteName: TopShelfCachePolicy.appGroup),
              let stored = defaults.object(forKey: defaultsKey) as? NSNumber
        else { return fallback }
        return stored.uint32Value
    }

    nonisolated static func write(_ hex: UInt32) {
        guard let defaults = UserDefaults(suiteName: TopShelfCachePolicy.appGroup) else { return }
        defaults.set(NSNumber(value: hex), forKey: defaultsKey)
    }
}
