import UIKit
import MediaPlayer
import AVFoundation

/// Sets the system output volume through a hidden MPVolumeView slider (there is no public direct
/// setter) and reads it back from the audio session. Used by the player's vertical-swipe volume
/// gesture. The hidden view is parked off-screen in the key window the first time it is needed.
enum PlayerSystemVolume {
    @MainActor private static let host: MPVolumeView = {
        let view = MPVolumeView(frame: .zero)
        view.alpha = 0.0001
        view.isUserInteractionEnabled = false
        return view
    }()

    /// Parks the hidden view in the key window. Its mere presence suppresses the native iOS volume
    /// overlay, so this is only called once our own player HUD is ready to take over (first `.playing`,
    /// or an active volume swipe), never during load or elsewhere in the app. Idempotent.
    @MainActor static func activate() {
        guard host.superview == nil else { return }
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?
            .addSubview(host)
    }

    /// Removes the hidden view on player teardown so the native volume overlay is restored everywhere
    /// else in the app (it used to leak, staying parked for the whole process once any swipe parked it).
    @MainActor static func deactivate() {
        host.removeFromSuperview()
    }

    /// True while we own the overlay (host parked). The hardware volume-button HUD is gated on this so it
    /// only fires when the native overlay is actually suppressed, never producing a phantom or double HUD.
    @MainActor static var isActive: Bool { host.superview != nil }

    @MainActor static func set(_ value: Float) {
        activate()
        if let slider = host.subviews.compactMap({ $0 as? UISlider }).first {
            slider.value = min(max(value, 0), 1)
        }
    }

    static var current: Float {
        AVAudioSession.sharedInstance().outputVolume
    }
}
