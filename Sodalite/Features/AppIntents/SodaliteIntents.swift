import AppIntents
import Foundation

// MARK: - Open App

/// Foundation phrase for App Shortcuts; surfaces "Open Sodalite" in Siri suggestions and the Shortcuts app.
struct OpenSodaliteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Sodalite"
    static let description = IntentDescription("Open the Sodalite app.")
    static let openAppWhenRun: Bool = true
    /// `.alwaysAllowed` lets tvOS-Siri voice-invoke without the unlock prompt; else Siri refuses with "unterstützt diesen Vorgang mit Siri nicht".
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

// MARK: - Continue Watching

/// Resumes the most recent Resume-queue item via the `requestContinueWatching` channel (`AppRouter` does the fetch + nav). Flips a bool and returns immediately because Siri-via-tvOS-remote rejects intents whose `perform()` does async work.
struct ContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription("Resume your most recent show or movie on Sodalite.")
    static let openAppWhenRun: Bool = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.appState?.requestContinueWatching = true
        return .result()
    }
}
