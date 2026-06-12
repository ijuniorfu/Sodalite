import UIKit
import AetherEngine

/// Shared deep-link teardown for the UIKit-presented player modal.
/// Used by SodaliteApp's synchronous URL handler and AppRouter's
/// pending-link resolver: both need any active player gone before a
/// new detail sheet can land, and the SwiftUI binding-only dismiss
/// path proved unreliable across the scene-foreground transition (a
/// TopShelf tap that resumes the app from a paused player would not
/// always dispatch the local-state mutation through to UIKit fast
/// enough to let the new fullScreenCover present on top).
@MainActor
enum PlayerModalDismisser {
    /// Walk the active scene's window-level modal chain and dismiss
    /// the `PlayerHostController` if one is presented.
    ///
    /// Calling `dismiss(animated:)` on the VC that directly presented
    /// the player removes only that modal level; any other modals in
    /// the chain are left alone. Logged via EngineLog (tagged with the
    /// caller's `logPrefix`) so the diagnostic overlay can confirm the
    /// path ran on TestFlight.
    static func dismissActive(logPrefix: String) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .background }),
              let window = scene.windows.first(where: { $0.isKeyWindow })
                ?? scene.windows.first
        else {
            EngineLog.emit("\(logPrefix) deep-link dismiss: no key window")
            return
        }

        var presenter: UIViewController? = window.rootViewController
        while let current = presenter {
            guard let presented = current.presentedViewController else { break }
            if presented is PlayerHostController {
                EngineLog.emit("\(logPrefix) deep-link dismiss: tearing down active player modal")
                current.dismiss(animated: false)
                return
            }
            presenter = presented
        }
        EngineLog.emit("\(logPrefix) deep-link dismiss: no player in modal chain")
    }
}
