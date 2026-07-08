import Foundation

/// Pure decision for whether the external-display subtitle window should be shown (Sodalite#98). Kept
/// separate and pure so the gating is self-evident and testable without a UIWindow. Show only when a
/// subtitle is selected, a wired external screen is present, and native subtitle renditions are NOT
/// already reaching it (that stays the DrHurt-confirmed #34 path on an HDR external display).
enum ExternalSubtitleWindowDecision {
    static func shouldShow(
        externalScreenPresent: Bool, subtitleSelected: Bool, nativeRenditionsServed: Bool
    ) -> Bool {
        externalScreenPresent && subtitleSelected && !nativeRenditionsServed
    }
}

#if os(iOS)
import UIKit
import SwiftUI

/// Owns the transparent UIWindow on a wired external UIScreen that draws subtitles over AVPlayer's
/// external-playback video (Sodalite#98). Idempotent: `update(...)` shows or hides based on the pure
/// decision. Device-shakeout note: whether the window composites OVER the external-playback video (vs
/// displacing it) is only testable on a wired-HDMI rig; if it displaces the video, the approach must
/// move to rendering the video in this window too (spec approach B).
@MainActor
final class ExternalSubtitleWindowController {
    private var window: UIWindow?

    /// The connected external screen, if any. On wired HDMI the external display appears here; AirPlay
    /// video and PiP do not, which is the wired-HDMI-only discriminator.
    static func currentExternalScreen() -> UIScreen? {
        UIScreen.screens.first { $0 !== UIScreen.main }
    }

    func update(
        externalScreenPresent: Bool, subtitleSelected: Bool,
        nativeRenditionsServed: Bool, viewModel: PlayerViewModel
    ) {
        let show = ExternalSubtitleWindowDecision.shouldShow(
            externalScreenPresent: externalScreenPresent,
            subtitleSelected: subtitleSelected,
            nativeRenditionsServed: nativeRenditionsServed)
        if show, let screen = Self.currentExternalScreen() {
            showWindow(on: screen, viewModel: viewModel)
        } else {
            tearDown()
        }
    }

    private func showWindow(on screen: UIScreen, viewModel: PlayerViewModel) {
        if let window, window.screen === screen { return } // already up on this screen
        tearDown()
        let host = UIHostingController(rootView: ExternalSubtitleView(viewModel: viewModel))
        host.view.backgroundColor = .clear
        // Prefer the external display's own window scene (iOS 16+ non-interactive external role); fall
        // back to the deprecated screen-based window if no such scene is vended.
        let newWindow: UIWindow
        if let scene = Self.externalWindowScene(for: screen) {
            newWindow = UIWindow(windowScene: scene)
        } else {
            newWindow = UIWindow(frame: screen.bounds)
            newWindow.screen = screen
        }
        newWindow.backgroundColor = .clear
        newWindow.isUserInteractionEnabled = false
        newWindow.rootViewController = host
        newWindow.isHidden = false
        window = newWindow
        LogTap.shared.note("[ExternalSubs] window up on external screen \(screen.bounds.size)")
    }

    func tearDown() {
        guard window != nil else { return }
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        LogTap.shared.note("[ExternalSubs] window torn down")
    }

    private static func externalWindowScene(for screen: UIScreen) -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.screen === screen }
    }
}
#endif
