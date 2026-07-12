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

    @MainActor static func set(_ value: Float) {
        if host.superview == nil {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first?
                .addSubview(host)
        }
        if let slider = host.subviews.compactMap({ $0 as? UISlider }).first {
            slider.value = min(max(value, 0), 1)
        }
    }

    static var current: Float {
        AVAudioSession.sharedInstance().outputVolume
    }
}
