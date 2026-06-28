#if os(iOS)
import SwiftUI
import UIKit

/// Full-screen transparent catcher for the iOS player's screen gestures. It sits at the bottom of
/// the overlay z-stack (below the controls, above the video) so taps on the controls hit the
/// controls and taps on empty video hit this. Single-tap toggles controls; double-tap on the
/// left/right third skips -/+10s (middle = play/pause); a vertical drag sets brightness (left half)
/// or volume (right half). Mapping is shared with the unit-tested PlayerTouchInput.
struct PlayerGestureCatcher: View {
    let viewModel: PlayerViewModel

    @State private var panAxis: PanAxis = .undecided
    @State private var panStartLevel: Double = 0
    private enum PanAxis { case undecided, vertical, horizontalIgnored }
    private let skipInterval: Double = 10

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2, coordinateSpace: .local) { location in
                    if let seconds = PlayerTouchInput.skipSeconds(forTapX: location.x, width: geo.size.width, interval: skipInterval) {
                        viewModel.skip(by: seconds)
                    } else {
                        viewModel.togglePlayPause()
                    }
                }
                .onTapGesture {
                    if viewModel.showControls { viewModel.hideControls() }
                    else { viewModel.showControlsTemporarily() }
                }
                .gesture(verticalPan(in: geo.size))
        }
    }

    private func verticalPan(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                if panAxis == .undecided {
                    panAxis = abs(value.translation.height) > abs(value.translation.width) ? .vertical : .horizontalIgnored
                    let onLeft = value.startLocation.x < size.width / 2
                    panStartLevel = onLeft ? Double(Self.currentBrightness) : Double(PlayerSystemVolume.current)
                }
                guard panAxis == .vertical else { return }
                let onLeft = value.startLocation.x < size.width / 2
                let level = panStartLevel + PlayerTouchInput.levelDelta(translationY: value.translation.height, height: size.height)
                if onLeft { viewModel.setBrightness(CGFloat(level)) }
                else { viewModel.setVolume(Float(level)) }
            }
            .onEnded { _ in panAxis = .undecided }
    }

    private static var currentBrightness: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.screen.brightness ?? 0.5
    }
}
#endif
