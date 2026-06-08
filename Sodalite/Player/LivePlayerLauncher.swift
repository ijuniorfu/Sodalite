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
        guard isPresented, let liveContext = self.context,
              let window = host.viewIfLoaded?.window,
              var top = window.rootViewController else { return }
        // Present from the topmost presented VC. The info popover (a SwiftUI
        // sheet) is presented from this same host, so guarding on
        // host.presentedViewController == nil blocked the player; stacking on
        // the topmost VC presents reliably regardless of the sheet's state.
        while let presented = top.presentedViewController { top = presented }
        print("[LivePlayerLauncher] topmost=\(type(of: top))")
        guard !(top is PlayerHostController) else { return }

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
        var playerRef: PlayerHostController?
        let playerVC = PlayerHostController(
            viewModel: vm,
            tintColor: tintColor,
            onDismiss: {
                playerRef?.presentingViewController?.dismiss(animated: false) { isPresented = false }
            }
        )
        playerRef = playerVC
        playerVC.modalPresentationStyle = .fullScreen
        print("[LivePlayerLauncher] presenting live player for channel=\(liveContext.channel.name) from=\(type(of: top))")
        top.present(playerVC, animated: false)
    }
}
