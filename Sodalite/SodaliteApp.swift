import SwiftUI
import UIKit
import AetherEngine

@main
struct SodaliteApp: App {
    @State private var appState = AppState()
    @State private var dependencies = DependencyContainer()

    init() {
        // Hand the live AppState/DependencyContainer to the intent
        // layer so AppIntent.perform() can drive navigation and
        // hit Jellyfin without rebuilding its own DI graph.
        IntentBridge.bind(appState: appState, dependencies: dependencies)

        // Wire AetherEngine's diagnostic broadcaster to the in-app
        // log overlay. Only in diagnostic builds (DEBUG / TestFlight),
        // App Store builds leave the handler nil so the engine emits
        // to print() only.
        if LogTap.isDiagnosticBuild {
            EngineLog.handler = { line in
                LogTap.shared.note(line)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRouter()
                .environment(\.appState, appState)
                .environment(\.dependencies, dependencies)
                .preferredColorScheme(.dark)
                .tint(dependencies.appearancePreferences.effectiveTint(
                    isSupporter: dependencies.storeKitService.isSupporter
                ))
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    /// `sodalite://item/{id}` is the only scheme we honor today,
    /// emitted by the TopShelf extension's cell `displayAction`.
    /// Stash the id in AppState; AppRouter watches that field, fetches
    /// the full item, and presents the detail sheet once the session
    /// has finished restoring on cold launches.
    ///
    /// Synchronously tears down any active player modal before the
    /// AppRouter task runs. Without this, a TopShelf tap that wakes
    /// the app from a paused player loses ~10s to the player's own
    /// `appDidBecomeActive` reload pipeline before AppRouter's
    /// `.task(id:)` gets cycled in, and the user stares at the stale
    /// session restarting before anything happens.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "sodalite", url.host == "item" else { return }
        let id = url.pathComponents.dropFirst().first ?? ""
        guard !id.isEmpty else { return }
        dismissActivePlayerModal()
        appState.requestPlayerDismissal &+= 1
        appState.pendingDeepLinkItemID = id
    }

    /// Walk the active scene's window-level modal chain and dismiss
    /// the `PlayerHostController` if one is presented. Called
    /// synchronously from the URL handler so the teardown happens
    /// before the engine reload kicks in.
    private func dismissActivePlayerModal() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .background }),
              let window = scene.windows.first(where: { $0.isKeyWindow })
                ?? scene.windows.first
        else {
            EngineLog.emit("[SodaliteApp] deep-link dismiss: no key window")
            return
        }

        var presenter: UIViewController? = window.rootViewController
        while let current = presenter {
            guard let presented = current.presentedViewController else { break }
            if presented is PlayerHostController {
                EngineLog.emit("[SodaliteApp] deep-link dismiss: tearing down active player modal")
                current.dismiss(animated: false)
                return
            }
            presenter = presented
        }
        EngineLog.emit("[SodaliteApp] deep-link dismiss: no player in modal chain")
    }
}
