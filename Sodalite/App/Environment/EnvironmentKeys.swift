import SwiftUI

private struct DependencyContainerKey: EnvironmentKey {
    // Shared singleton, NOT a fresh instance (a fresh container spawns a zombie MusicPlaybackCoordinator that clears system Now-Playing).
    static let defaultValue = DependencyContainer.shared
}

private struct AppStateKey: EnvironmentKey {
    static let defaultValue = AppState.shared
}

extension EnvironmentValues {
    var dependencies: DependencyContainer {
        get { self[DependencyContainerKey.self] }
        set { self[DependencyContainerKey.self] = newValue }
    }

    var appState: AppState {
        get { self[AppStateKey.self] }
        set { self[AppStateKey.self] = newValue }
    }
}
