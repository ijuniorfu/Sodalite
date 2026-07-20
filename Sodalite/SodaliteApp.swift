import SwiftUI
import AetherEngine
import UIKit

#if os(iOS)
/// Drives app orientation: the app rotates freely on iPhone; a fullscreen player session narrows it
/// via PlayerOrientation.playerMask (nil in follow mode = free rotation); iPad allows all. The
/// delegate method overrides Info.plist at runtime.
final class OrientationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return PlayerOrientation.playerMask ?? .allButUpsideDown
    }
}
#endif

@main
struct SodaliteApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(OrientationAppDelegate.self) private var orientationDelegate
    #endif

    // Shared singletons, NOT fresh instances: SwiftUI may build the App value and the @Environment default separately, and a fresh DependencyContainer spawns a zombie MusicPlaybackCoordinator that clears system Now-Playing on every engine state change.
    @State private var appState = AppState.shared
    @State private var dependencies = DependencyContainer.shared

    init() {
        // Back-wire so switchServer/removeServer can bump serverDidSwitch; must run before any switch fires.
        dependencies.appState = appState

        // Now that appState is wired, connect the pending-requests monitor (reads appState + Seerr service).
        dependencies.wirePendingRequestsMonitor()

        #if os(iOS)
        // Register the background refresh that fires a local notification when new requests await approval.
        let deps = dependencies
        PendingRequestsBackgroundRefresh.register {
            let prefs = deps.seerrNotificationPreferences
            guard prefs.notifyPendingRequests else { return false }
            await PendingRequestsSync.refreshAndSync(monitor: deps.pendingRequestsMonitor, preferences: prefs)
            return true
        }
        // Show notifications as banners even while the app is foregrounded.
        PendingRequestsNotifier.configureForegroundPresentation()
        #endif

        // Hand the live AppState/DependencyContainer to the intent layer so AppIntent.perform() drives navigation without rebuilding its own DI graph.
        IntentBridge.bind(appState: appState, dependencies: dependencies)

        // Cloud sync: attach after the container is fully built, then register
        // for the silent CloudKit pushes that drive near-real-time propagation.
        dependencies.attachCloudSync()
        Task { @MainActor in
            UIApplication.shared.registerForRemoteNotifications()
        }

        // Wire AetherEngine diagnostics into the in-app log overlay; diagnostic builds (DEBUG/TestFlight) only, App Store leaves it nil (OSLog only).
        if LogTap.isDiagnosticBuild {
            EngineLog.handler = { line in
                LogTap.shared.note(line)
            }
        }

        // Re-derive the cached TestFlight/sandbox flag from StoreKit 2; takes effect next launch (see LogTap.isDiagnosticBuild).
        Task {
            await LogTap.refreshDiagnosticBuildFlag()
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

    /// Handles `sodalite://item/{id}` (only scheme, from TopShelf's displayAction): stashes the id in AppState for AppRouter to resolve. Synchronously tears down any active player modal first, else a TopShelf tap waking the app from a paused player loses ~10s to the player's own appDidBecomeActive reload before AppRouter's .task(id:) cycles in.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "sodalite", url.host == "item" else { return }
        let id = url.pathComponents.dropFirst().first ?? ""
        guard !id.isEmpty else { return }
        PlayerModalDismisser.dismissActive(logPrefix: "[SodaliteApp]")
        appState.requestPlayerDismissal &+= 1
        // Mask the prior detail view during the fetch + cover slide-in; AppRouter clears this once the new sheet takes over.
        appState.isResolvingDeepLink = true
        appState.pendingDeepLinkItemID = id
    }
}
