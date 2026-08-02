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

    /// Interface orientation the app held when the session engaged; the exit rotates back to it.
    private static var entryOrientation: UIInterfaceOrientation = .portrait
    /// Exit rotation in flight: the mask stays pinned to `entryOrientation` until it lands.
    private static var isRestoring = false
    private static var restoreGeneration = 0

    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// Launch entry, also re-fired by viewWillAppear (HDR mode switches re-trigger it): applies the
    /// persisted mode, but never stomps a mode the in-player lock toggle already set this session.
    static func engage(locked: Bool) {
        guard isPhone else { return }
        // A pending exit restore still owns the mask; drop it so a relaunch inside that window engages.
        if isRestoring { endRestore() }
        guard playerMask == nil, !isFollowing else { return }
        entryOrientation = currentOrientation
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

    /// Session exit: rotate back to the orientation the app came in with.
    ///
    /// The mask is narrowed to that orientation BEFORE the request, exactly as `lock()` narrows to
    /// landscape on the way in. Releasing it to nil first (allButUpsideDown) leaves the landscape the
    /// player sits in a supported orientation, so the system has no reason to leave it and resolves the
    /// exit right back to landscape. The device attitude used to paper over that, which is why the app
    /// stayed landscape only with the system rotation lock on: with no attitude to fall back on nothing
    /// pulled it out again, and short of backgrounding the app there was no way back (Sodalite#54).
    static func unlock() {
        guard isPhone, !isRestoring else { return }
        isFollowing = false
        isRestoring = true
        let target = mask(for: entryOrientation)
        playerMask = target
        apply(target)
        releaseWhenSettled()
    }

    /// The pin holds only until the rotation lands: a permanently portrait-pinned app would kill
    /// landscape browsing. The timeout releases a rotation that never arrives rather than stranding it.
    private static func releaseWhenSettled() {
        restoreGeneration += 1
        let generation = restoreGeneration
        let target = entryOrientation
        Task { @MainActor in
            for _ in 0..<40 {
                if currentOrientation == target { break }
                try? await Task.sleep(for: .milliseconds(50))
                guard generation == restoreGeneration else { return }
            }
            guard generation == restoreGeneration, isRestoring else { return }
            endRestore()
            refreshSupportedOrientations()
        }
    }

    private static func endRestore() {
        isRestoring = false
        restoreGeneration += 1
        playerMask = nil
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
        scene?.effectiveGeometry.interfaceOrientation ?? .landscapeRight
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
