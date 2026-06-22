import AppIntents

/// Surfaces intents to Siri/Shortcuts; phrases matched from localized `AppShortcuts.xcstrings` per language.
/// Only `OpenSodaliteIntent` is exposed: tvOS Siri rejects non-system-schema custom intents at voice-invoke ("doesn't support this with Siri"), but "Open [App]" is system-blessed via LSOpenURL. `ContinueWatchingIntent` stays in the codebase for the Shortcuts app on iPhone/iPad/Mac where custom intents work.
struct SodaliteShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSodaliteIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Launch \(.applicationName)",
                "Show \(.applicationName)",
            ],
            shortTitle: "Open",
            systemImageName: "play.tv"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
