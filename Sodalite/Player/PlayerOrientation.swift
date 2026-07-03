#if os(iOS)
import UIKit

/// Process-wide orientation policy for the fullscreen player. `OrientationAppDelegate` reads
/// `playerMask` from `application(_:supportedInterfaceOrientationsFor:)`. Locked mode pins the
/// session (landscape at launch, the orientation the user holds when re-locking in-player);
/// follow mode leaves rotation to the device. iPad is never managed (it allows all).
enum PlayerOrientation {
    /// Orientation mask the player session enforces; nil while no player is up, or in follow mode.
    static private(set) var playerMask: UIInterfaceOrientationMask?
    /// Player session up with rotation following the device (lock icon open).
    static private(set) var isFollowing = false

    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// Launch entry, also re-fired by viewWillAppear (HDR mode switches re-trigger it): applies the
    /// persisted mode, but never stomps a mode the in-player lock toggle already set this session.
    static func engage(locked: Bool) {
        guard isPhone, playerMask == nil, !isFollowing else { return }
        if locked { lock() } else { follow() }
    }

    static func lock() {
        guard isPhone else { return }
        isFollowing = false
        playerMask = .landscape
        apply(.landscapeRight)
    }

    /// In-player re-lock: freeze whatever orientation the user is holding, system-rotation-lock style.
    static func lockToCurrent() {
        guard isPhone else { return }
        isFollowing = false
        let mask = mask(for: currentOrientation)
        playerMask = mask
        apply(mask)
    }

    static func follow() {
        guard isPhone else { return }
        isFollowing = true
        playerMask = nil
        // No forced rotation; widening the allowed set lets the device attitude take over.
        refreshSupportedOrientations()
    }

    static func unlock() {
        guard isPhone else { return }
        isFollowing = false
        playerMask = nil
        apply(.portrait)
    }

    /// Presentation orientation for the player modal: landscape when locked, whatever the user holds when following.
    static var presentationOrientation: UIInterfaceOrientation {
        isFollowing ? currentOrientation : .landscapeRight
    }

    private static var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
    }

    private static var currentOrientation: UIInterfaceOrientation {
        scene?.interfaceOrientation ?? .landscapeRight
    }

    private static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: .landscape
        }
    }

    private static func apply(_ orientation: UIInterfaceOrientationMask) {
        guard let scene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
        refreshSupportedOrientations()
    }

    /// The player modal owns the orientation decision while presented, so the update must reach the
    /// top-most presented VC, not just the root (which sufficed when every mode change also forced a rotation).
    private static func refreshSupportedOrientations() {
        guard let root = scene?.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.setNeedsUpdateOfSupportedInterfaceOrientations()
        if top !== root { root.setNeedsUpdateOfSupportedInterfaceOrientations() }
    }
}
#endif
