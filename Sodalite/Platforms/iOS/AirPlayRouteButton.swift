import SwiftUI
import AVKit

/// Wraps the system AirPlay route picker (AVRoutePickerView) for the touch player's top bar.
/// prioritizesVideoDevices so it offers Apple TVs / video-capable routes first. (External-playback
/// routing of the engine loopback is a separate Cast step; the button is present for discoverability.)
struct AirPlayRouteButton: UIViewRepresentable {
    var tint: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tint
        view.activeTintColor = tint
        view.prioritizesVideoDevices = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = tint
    }
}
