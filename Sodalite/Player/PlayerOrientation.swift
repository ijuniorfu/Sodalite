#if os(iOS)
import UIKit

/// Process-wide landscape lock for the fullscreen player. `OrientationAppDelegate` reads
/// `lockLandscape` from `application(_:supportedInterfaceOrientationsFor:)`; `lock()` / `unlock()`
/// flip it and ask the active window scene to rotate immediately. iPad is never locked (it allows all).
enum PlayerOrientation {
    static private(set) var lockLandscape = false

    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    static func lock() {
        guard isPhone else { return }
        lockLandscape = true
        apply(.landscapeRight)
    }

    static func unlock() {
        guard isPhone else { return }
        lockLandscape = false
        apply(.portrait)
    }

    private static func apply(_ orientation: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
#endif
