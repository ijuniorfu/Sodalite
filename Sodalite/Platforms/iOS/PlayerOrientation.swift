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

    /// Interface orientation the app held when the session engaged; the exit rotates back to it.
    private static var entryOrientation: UIInterfaceOrientation = .portrait
    /// Exit rotation in flight: the mask stays pinned to `entryOrientation` until it lands.
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
    /// view controller that is going away must not re-engage the lock, which would cancel the exit
    /// rotation and pin landscape with no player on screen.
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
        entryOrientation = currentOrientation
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

    /// Session exit: rotate back to the orientation the app came in with.
    ///
    /// The mask is narrowed to that orientation BEFORE the request, exactly as `lock()` narrows to
    /// landscape on the way in. Releasing it to nil first (allButUpsideDown) leaves the landscape the
    /// player sits in a supported orientation, so the system has no reason to leave it and resolves the
    /// exit right back to landscape. The device attitude used to paper over that, which is why the app
    /// stayed landscape only with the system rotation lock on: with no attitude to fall back on nothing
    /// pulled it out again, and short of backgrounding the app there was no way back (Sodalite#54).
    static func unlock(session: Int) {
        guard isPhone else { return }
        exitedSession = max(exitedSession, session)
        guard !isRestoring else { return }
        isFollowing = false
        stopAttitudeTracking()
        isRestoring = true
        let target = mask(for: entryOrientation)
        playerMask = target
        apply(target)
        releaseWhenSettled()
    }

    /// The pin holds until the rotation has landed AND the player modal is really gone: a permanently
    /// portrait-pinned app would kill landscape browsing, but releasing it while the dismissal is still
    /// in flight hands the decision back to a view controller that is still on screen and still asks for
    /// landscape. `effectiveGeometry` reports the target well before the dismiss transition ends, so on
    /// a slower phone that release lands after the portrait rotation is already visible: the app flicks
    /// straight back to landscape and, with no further event to re-resolve it, stays there until it is
    /// backgrounded (Sodalite#54 retest, invisible on faster hardware where the modal wins the race).
    /// The timeout releases a rotation that never arrives rather than stranding it.
    private static func releaseWhenSettled() {
        restoreGeneration += 1
        let generation = restoreGeneration
        let target = entryOrientation
        Task { @MainActor in
            for _ in 0..<40 {
                if currentOrientation == target, !PlayerModalPresence.isPlayerActive { break }
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

    /// Presentation orientation for the player modal: landscape when locked, whatever the user holds
    /// when following, and the exit target while a restore runs. UIKit keeps consulting the dismissing
    /// controller for the length of the transition, and a modal that asks for landscape there argues
    /// against the rotation its own exit just requested.
    static var presentationOrientation: UIInterfaceOrientation {
        if isRestoring { return entryOrientation }
        return isFollowing ? currentOrientation : .landscapeRight
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
