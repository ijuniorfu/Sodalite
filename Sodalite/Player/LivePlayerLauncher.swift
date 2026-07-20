import SwiftUI
import UIKit

// MARK: - Live Player Launcher (UIKit modal presentation)

/// UIKit-modal launcher for the live player (mirrors PlayerLauncher with the
/// live initializer); presents when `isPresented` and `context` are set.
struct LivePlayerLauncher: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let context: LivePlaybackContext?
    let playbackService: JellyfinPlaybackServiceProtocol
    let liveTvService: JellyfinLiveTvServiceProtocol
    let userID: String
    let preferences: PlaybackPreferences
    var tintColor: Color?

    func makeUIViewController(context: Context) -> PlayerLauncherHostVC {
        PlayerLauncherHostVC()
    }

    func updateUIViewController(_ host: PlayerLauncherHostVC, context: Context) {
        if isPresented, let liveContext = self.context {
            guard host.viewIfLoaded?.window != nil else { return }
            if host.presentedViewController is PlayerHostController || host.pendingLivePresent { return }
            host.pendingLivePresent = true
            attemptPresent(host: host, liveContext: liveContext, attempt: 0)
        } else if !isPresented, host.presentedViewController is PlayerHostController {
            // Programmatic dismissal (sign-out, deep link, teardown); else the
            // live player stays as a zombie modal.
            host.dismiss(animated: false)
        }
    }

    /// Present only once the info popover (a SwiftUI sheet from this host) has
    /// finished dismissing; presenting mid-dismiss fails ("view is not in the
    /// window hierarchy"), so poll (40 x 50ms) until host has nothing presented.
    private func attemptPresent(host: PlayerLauncherHostVC, liveContext: LivePlaybackContext, attempt: Int) {
        // Binding can flip false during the poll (user backed out); don't
        // launch a player nobody asked for.
        guard isPresented else {
            host.pendingLivePresent = false
            return
        }
        if let presented = host.presentedViewController, !(presented is PlayerHostController) {
            guard attempt < 40 else { host.pendingLivePresent = false; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                attemptPresent(host: host, liveContext: liveContext, attempt: attempt + 1)
            }
            return
        }
        host.pendingLivePresent = false
        if host.presentedViewController is PlayerHostController { return }

        // Second video while PiP runs: close the PiP session first (progress reported), Netflix behavior.
        #if os(tvOS)
        PiPSessionCoordinator.shared.endActiveSession()
        #endif

        let item = JellyfinItem(liveChannel: liveContext.channel, program: liveContext.program)
        let vm = PlayerViewModel(
            item: item,
            startFromBeginning: true,
            playbackService: playbackService,
            userID: userID,
            preferences: preferences,
            isLiveSession: true,
            liveChannel: liveContext.channel,
            liveTvService: liveTvService
        )
        let playerVC = PlayerHostController(
            viewModel: vm,
            tintColor: tintColor,
            onDismiss: {
                host.dismiss(animated: false) { isPresented = false }
            }
        )
        playerVC.modalPresentationStyle = .fullScreen
        host.present(playerVC, animated: false)
    }
}
