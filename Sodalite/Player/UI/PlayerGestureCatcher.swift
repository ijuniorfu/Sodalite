#if os(iOS)
import SwiftUI
import UIKit

/// Full-screen SwiftUI gesture catcher at the bottom of the overlay z-stack (below the controls,
/// above the video): single-tap toggles controls (and closes a dropdown via hideControls),
/// double-tap on the left/right third skips -/+10s (middle = play/pause), a vertical drag sets
/// brightness (left half) / volume (right half). A plain SwiftUI layer (Color.clear) reliably
/// receives empty-area taps in the hosting overlay; the controls render above and win their own hits.
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
                .simultaneousGesture(verticalPan(in: geo.size))
        }
    }

    private func verticalPan(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                if panAxis == .undecided {
                    panAxis = abs(value.translation.height) > abs(value.translation.width) ? .vertical : .horizontalIgnored
                    let onLeft = value.startLocation.x < size.width / 2
                    panStartLevel = onLeft ? Double(Self.brightness) : Double(PlayerSystemVolume.current)
                }
                guard panAxis == .vertical else { return }
                let onLeft = value.startLocation.x < size.width / 2
                let level = panStartLevel + PlayerTouchInput.levelDelta(translationY: value.translation.height, height: size.height)
                if onLeft { viewModel.setBrightness(CGFloat(level)) } else { viewModel.setVolume(Float(level)) }
            }
            .onEnded { _ in panAxis = .undecided }
    }

    private static var brightness: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.screen.brightness ?? 0.5
    }
}
#endif
