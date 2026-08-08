import UIKit

/// Process-wide orientation policy for the fullscreen player. `OrientationAppDelegate` reads
/// `playerMask` from `application(_:supportedInterfaceOrientationsFor:)`. Locked mode pins the
/// session (landscape at launch, the orientation the user holds when re-locking in-player);
/// follow mode tracks the device attitude. iPad is never managed (it allows all).
enum PlayerOrientation {
    /// Orientation mask the player session enforces; nil while no player is up. Follow mode keeps it
    /// narrowed to the orientation the device is held in, see `follow()`.
    static private(set) var playerMask: UIInterfaceOrientationMask?
    /// Player session up with rotation following the device (lock icon open).
    static private(set) var isFollowing = false

    /// Exit in flight: the session mask stays in force until the player modal is off screen.
    private static var isRestoring = false
    private static var restoreGeneration = 0
    /// Monotonic player-session identity, handed out by `newSession()`.
    private static var sessionCounter = 0
    /// Highest session that has already run its exit. Sessions are monotonic, so anything at or below
    /// this is over and may no longer engage.
    private static var exitedSession = 0

    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// Identity for one player session, minted by `PlayerHostController` and passed to
    /// `engage`/`unlock`. The exit is terminal for that session: a late lifecycle callback from the
    /// view controller that is going away must not re-engage the lock, which would pin landscape
    /// again with no player on screen.
    static func newSession() -> Int {
        sessionCounter += 1
        return sessionCounter
    }

    /// Launch entry, also re-fired by viewWillAppear (HDR mode switches re-trigger it): applies the
    /// persisted mode, but never stomps a mode the in-player lock toggle already set this session.
    static func engage(locked: Bool, session: Int) {
        guard isPhone, session > exitedSession else { return }
        // A pending exit restore still owns the mask; drop it so a relaunch inside that window engages.
        if isRestoring { endRestore() }
        guard playerMask == nil, !isFollowing else { return }
        if locked { lock() } else { follow() }
    }

    static func lock() {
        guard isPhone else { return }
        isFollowing = false
        stopAttitudeTracking()
        playerMask = .landscape
        apply(.landscapeRight)
    }

    /// In-player re-lock: freeze whatever orientation the user is holding, system-rotation-lock style.
    static func lockToCurrent() {
        guard isPhone else { return }
        isFollowing = false
        stopAttitudeTracking()
        let mask = mask(for: currentOrientation)
        playerMask = mask
        apply(mask)
    }

    /// Follow mode drives the rotation from the device attitude instead of handing the decision back
    /// to the system.
    ///
    /// Widening the mask is not the same thing: with the system rotation lock on there is no attitude
    /// input left, so the app resolves to the locked orientation (portrait) and the toggle becomes a
    /// one-way door, opening it drops the video into portrait and closing it pins portrait, with no way
    /// back to landscape for the rest of the session (Sodalite#54). An open padlock in a video player
    /// means "turn with the phone", so the phone is what it follows, system lock or not.
    static func follow() {
        guard isPhone else { return }
        isFollowing = true
        startAttitudeTracking()
        // A phone lying flat reports .faceUp and carries no attitude yet; hold the current orientation
        // until the first real reading arrives rather than guessing one.
        let held = interfaceOrientation(for: UIDevice.current.orientation) ?? currentOrientation
        let target = mask(for: held)
        playerMask = target
        apply(target)
    }

    /// Session exit: hand the orientation decision back to the system, once the player is off screen.
    ///
    /// The exit picks no target of its own, on purpose. Rotating back to the orientation the session
    /// started in is wrong the moment the user turns the phone during playback: the app snaps to the
    /// entry orientation and the device attitude immediately pulls it back out, one visible bounce per
    /// exit, in both directions. The system resolves this correctly for every screen that is not the
    /// player, the attitude when rotation is free and the locked orientation when the system rotation
    /// lock is on, and it is the only party that can, the app cannot read the rotation lock. So it
    /// gets asked (`releaseToSystem`) instead of second-guessed.
    ///
    /// The ask only resolves correctly once the player is gone, which is the other half of
    /// Sodalite#54: hand the decision back while the dismissal is still running and it goes to a modal
    /// that is still on screen and still asks for landscape, after which nothing re-resolves and the
    /// app sits in landscape until it is backgrounded. Holding the session mask that long costs
    /// nothing, player and app root read the same mask, so the transition never lacks a common
    /// orientation.
    static func unlock(session: Int) {
        guard isPhone else { return }
        exitedSession = max(exitedSession, session)
        guard !isRestoring else { return }
        isFollowing = false
        stopAttitudeTracking()
        isRestoring = true
        releaseWhenPlayerIsGone()
    }

    /// `isPlayerActive` stays true for the length of the dismiss transition, which is exactly the
    /// window the release has to sit out. The 2 s cap releases a modal that never leaves rather than
    /// stranding the app in the session mask.
    private static func releaseWhenPlayerIsGone() {
        restoreGeneration += 1
        let generation = restoreGeneration
        Task { @MainActor in
            for _ in 0..<40 {
                if !PlayerModalPresence.isPlayerActive { break }
                try? await Task.sleep(for: .milliseconds(50))
                guard generation == restoreGeneration else { return }
            }
            guard generation == restoreGeneration, isRestoring else { return }
            endRestore()
            releaseToSystem()
        }
    }

    /// Handing the orientation back is an explicit request, not the absence of one.
    ///
    /// Dropping the mask only widens what is allowed, and the system keeps an orientation that is
    /// still allowed, so the app stays in the landscape the player forced. With rotation free the
    /// device attitude pulls it out a moment later and the defect is invisible; with the system
    /// rotation lock on there is no attitude input left, and the app sits in landscape until the lock
    /// is switched off or the app is backgrounded, which is the original Sodalite#54 report. The wide
    /// geometry request makes the system re-resolve, and it lands on the attitude or on the locked
    /// orientation depending on which of the two applies, without the app having to know which.
    private static func releaseToSystem() {
        refreshSupportedOrientations()
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .allButUpsideDown))
    }

    private static func endRestore() {
        isRestoring = false
        restoreGeneration += 1
        playerMask = nil
    }

    /// Presentation orientation for the player modal: landscape when locked, whatever the user holds
    /// when following or while the session is on its way out. UIKit keeps consulting the dismissing
    /// controller for the length of the transition, and a modal that asks for landscape there argues
    /// against the orientation the app is actually in.
    static var presentationOrientation: UIInterfaceOrientation {
        (isFollowing || isRestoring) ? currentOrientation : .landscapeRight
    }

    // MARK: - Attitude tracking (follow mode)

    /// `UIDevice` reports the attitude through a selector, so follow mode needs an object to aim it at.
    private final class AttitudeObserver: NSObject {
        @objc func deviceOrientationDidChange() { PlayerOrientation.applyDeviceOrientation() }
    }

    private static var attitudeObserver: AttitudeObserver?

    private static func startAttitudeTracking() {
        guard attitudeObserver == nil else { return }
        let observer = AttitudeObserver()
        attitudeObserver = observer
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            observer,
            selector: #selector(AttitudeObserver.deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    private static func stopAttitudeTracking() {
        guard let observer = attitudeObserver else { return }
        attitudeObserver = nil
        NotificationCenter.default.removeObserver(observer)
        // Refcounted, so the begin above needs exactly one end.
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    /// Rotates to the attitude the phone is held in. Upside down is ignored (the app is
    /// `allButUpsideDown` everywhere else), as are the flat and unknown readings, which carry no
    /// attitude at all: those keep the orientation the player already has.
    fileprivate static func applyDeviceOrientation() {
        guard isFollowing,
              scene?.activationState == .foregroundActive,
              let held = interfaceOrientation(for: UIDevice.current.orientation)
        else { return }
        let target = mask(for: held)
        guard target != playerMask else { return }
        playerMask = target
        apply(target)
    }

    /// Device attitude to interface orientation. The two landscapes are mirrored: holding the phone
    /// rotated to the left puts the interface in landscapeRight.
    private static func interfaceOrientation(for device: UIDeviceOrientation) -> UIInterfaceOrientation? {
        switch device {
        case .portrait: .portrait
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
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
