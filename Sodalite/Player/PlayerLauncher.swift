import SwiftUI
import UIKit

// MARK: - Player Launcher (UIKit modal presentation)

/// Presents PlayerHostController as a UIKit modal (NOT SwiftUI
/// fullScreenCover, which on tvOS intercepts Menu at the presentation level so
/// child-VC press handlers / .onExitCommand never fire).
struct PlayerLauncher: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let item: JellyfinItem?
    let startFromBeginning: Bool
    let playbackService: JellyfinPlaybackServiceProtocol
    let userID: String
    let preferences: PlaybackPreferences
    var cachedPlaybackInfo: PlaybackInfoResponse?
    /// Version picker's choice; nil = default-first source.
    var preferredMediaSourceID: String?
    /// Shuffle / play queue; empty = single-item playback.
    var playQueue: [JellyfinItem] = []
    /// Overlay tint, threaded through because WindowGroup `.tint(...)` doesn't
    /// cross into the UIKit modal; nil = asset-catalog default.
    var tintColor: Color?

    func makeUIViewController(context: Context) -> PlayerLauncherHostVC {
        PlayerLauncherHostVC()
    }

    func updateUIViewController(_ host: PlayerLauncherHostVC, context: Context) {
        if isPresented, let item, host.presentedViewController == nil, !host.isLaunching {
            // Latch the launch so a re-render while we wait for the presentation
            // context to settle can't build a second PlayerViewModel (each one
            // re-requests PlaybackInfo). This is what crashed #31: the version
            // picker is a sheet on the detail fullScreenCover, and presenting the
            // player before that sheet finished dismissing left presentedViewController
            // nil, so every re-render rebuilt the VM and churned PlaybackInfo until a
            // presentation assertion killed the app back to Home.
            host.isLaunching = true
            let isPresentedBinding = _isPresented
            host.presentWhenContextIsFree {
                let vm = PlayerViewModel(
                    item: item,
                    startFromBeginning: startFromBeginning,
                    playbackService: playbackService,
                    userID: userID,
                    preferences: preferences,
                    cachedPlaybackInfo: cachedPlaybackInfo,
                    preferredMediaSourceID: preferredMediaSourceID,
                    playQueue: playQueue
                )
                let playerVC = PlayerHostController(
                    viewModel: vm,
                    tintColor: tintColor,
                    onDismiss: {
                        host.dismiss(animated: false) {
                            host.isLaunching = false
                            isPresentedBinding.wrappedValue = false
                        }
                    }
                )
                playerVC.modalPresentationStyle = .fullScreen
                #if os(iOS)
                // Engage the landscape lock BEFORE presenting: the system validates the player VC's
                // supportedInterfaceOrientations (.landscape) against the app's allowed set at present
                // time, so the delegate must already permit landscape or it throws "no common orientation".
                PlayerOrientation.lock()
                #endif
                return playerVC
            }
        } else if !isPresented {
            // User backed out. Cancel any present still waiting on a busy context,
            // then tear down a live player if one is up.
            host.cancelPendingLaunch()
            if host.presentedViewController != nil {
                host.dismiss(animated: false)
            }
        }
    }
}

/// Invisible host VC: sits in the window hierarchy so UIKit present() works.
final class PlayerLauncherHostVC: UIViewController {
    /// Guards the live-player present retry loop against duplicate launches.
    var pendingLivePresent = false
    /// A launch is in flight (player VC built and/or waiting on a free
    /// presentation context). Blocks `updateUIViewController` from starting a
    /// second one, which would re-request PlaybackInfo (#31).
    var isLaunching = false
    /// Bumped on every launch request and on cancel so a stale, queued present
    /// attempt bails instead of presenting a player the user no longer wants.
    private var launchGeneration = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    /// Presents the player only once the window's presentation chain is settled.
    ///
    /// The detail screen is a fullScreenCover and the version-picker sheet shares
    /// its presentation context. Presenting the player while that sheet is still
    /// dismissing silently fails (presentedViewController stays nil), so the launcher
    /// would rebuild the VM and churn PlaybackInfo on every re-render until the app
    /// crashed to Home (#31). The previous fix waited a fixed 0.3s, which is too
    /// short on slower hardware (e.g. the 2015 Apple TV). This waits on the actual
    /// in-flight transition instead of guessing a delay.
    func presentWhenContextIsFree(_ build: @escaping () -> UIViewController) {
        launchGeneration &+= 1
        attemptPresent(generation: launchGeneration, build: build, attempts: 0)
    }

    /// Invalidates any queued present and clears the launch latch.
    func cancelPendingLaunch() {
        launchGeneration &+= 1
        isLaunching = false
    }

    private func attemptPresent(generation: Int, build: @escaping () -> UIViewController, attempts: Int) {
        // Superseded by a newer request, cancelled, or already presented.
        guard generation == launchGeneration, isLaunching, presentedViewController == nil else { return }

        if let transitioning = transitioningChainVC() {
            // Prefer the event-driven path: resume exactly when the in-flight
            // transition (the sheet dismissal) completes, no polling guesswork.
            if let coordinator = transitioning.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.attemptPresent(generation: generation, build: build, attempts: attempts + 1)
                }
                return
            }
            // Busy without a coordinator (e.g. host not yet in a window): poll the
            // next runloop, bounded to ~3s so a wedged chain can't spin forever.
            guard attempts < 180 else {
                isLaunching = false
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.attemptPresent(generation: generation, build: build, attempts: attempts + 1)
            }
            return
        }

        present(build(), animated: false)
    }

    /// The nearest VC in the window's presentation chain that is mid-transition
    /// (a sheet presenting or dismissing), or nil when the chain is settled and a
    /// present from here will land cleanly.
    private func transitioningChainVC() -> UIViewController? {
        guard let window = view.window, let root = window.rootViewController else {
            // Not in a window yet: treat as busy so we retry once attached.
            return self
        }
        var node: UIViewController? = root
        while let current = node {
            if current.transitionCoordinator != nil { return current }
            if let presented = current.presentedViewController {
                if presented.isBeingDismissed || presented.isBeingPresented { return presented }
                node = presented
            } else {
                node = nil
            }
        }
        return nil
    }
}
