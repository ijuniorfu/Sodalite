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
        print("[LivePlayerLauncher] update isPresented=\(isPresented) hasContext=\(self.context != nil) alreadyPresented=\(host.presentedViewController != nil) inWindow=\(host.viewIfLoaded?.window != nil)")
        if isPresented, let liveContext = self.context, host.presentedViewController == nil {
            print("[LivePlayerLauncher] presenting live player for channel=\(liveContext.channel.name)")
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
        } else if !isPresented, host.presentedViewController != nil {
            host.dismiss(animated: false)
        }
    }
}
