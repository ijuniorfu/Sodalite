import SwiftUI
import UIKit

// MARK: - Live Player Launcher (UIKit modal presentation)

/// UIKit-modal launcher for the live player, mirroring PlayerLauncher but
/// constructing the view model with the live initializer. Presents only when
/// `isPresented` is true and a `context` is set.
///
/// On tvOS, SwiftUI's fullScreenCover intercepts the Menu button at the
/// presentation level. UIKit modals don't have this problem.
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
            // Programmatic dismissal (sign-out, deep link, session
            // teardown flipping the binding): mirror PlayerLauncher,
            // otherwise the live player stays as a zombie modal.
            host.dismiss(animated: false)
        }
    }

    /// Present the player from the stable host VC, but only once the info
    /// popover (a SwiftUI sheet presented from this same host) has finished
    /// dismissing. Presenting while it is mid-dismiss fails ("view is not in
    /// the window hierarchy"), so poll until host has nothing presented.
    private func attemptPresent(host: PlayerLauncherHostVC, liveContext: LivePlaybackContext, attempt: Int) {
        // The binding can flip false during the poll window (user backed
        // out while the info sheet was still dismissing); presenting
        // anyway would launch a player nobody asked for.
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
