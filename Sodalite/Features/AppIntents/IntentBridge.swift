import Foundation

/// Hand-off between AppIntent `perform()` and the running scene. `openAppWhenRun = true` on each intent guarantees launch is done before `perform()` reads `appState`/`dependencies`; the intent mutates `pendingDeepLinkItemID`/`activeUser` and `AppRouter` observers drive navigation.
@MainActor
enum IntentBridge {
    static weak var appState: AppState?
    static weak var dependencies: DependencyContainer?

    static func bind(appState: AppState, dependencies: DependencyContainer) {
        Self.appState = appState
        Self.dependencies = dependencies
    }
}
