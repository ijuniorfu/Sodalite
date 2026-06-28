#if os(iOS)
import SwiftUI
import UIKit

/// Full-screen gesture catcher for the iOS player. A real UIKit view (with reliable
/// require(toFail:) double-tap disambiguation) placed at the bottom of the overlay z-stack: SwiftUI
/// controls above it hit-test first, empty video taps fall through to this. Single-tap toggles
/// controls (and closes any open dropdown via hideControls), double-tap on the left/right third
/// skips -/+10s (middle = play/pause), a vertical drag sets brightness (left) / volume (right).
struct PlayerGestureCatcher: UIViewRepresentable {
    let viewModel: PlayerViewModel

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator
        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.onSingle(_:)))
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.onDouble(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.onPan(_:)))
        for recognizer in [single, double, pan] {
            recognizer.delegate = c
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.viewModel = viewModel
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var viewModel: PlayerViewModel
        private let skipInterval: Double = 10
        private enum PanAxis { case undecided, vertical, horizontalIgnored }
        private var panAxis: PanAxis = .undecided
        private var panStartLevel: Double = 0

        init(viewModel: PlayerViewModel) { self.viewModel = viewModel }

        @objc func onSingle(_ recognizer: UITapGestureRecognizer) {
            if viewModel.showControls { viewModel.hideControls() }
            else { viewModel.showControlsTemporarily() }
        }

        @objc func onDouble(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let x = recognizer.location(in: view).x
            if let seconds = PlayerTouchInput.skipSeconds(forTapX: x, width: view.bounds.width, interval: skipInterval) {
                viewModel.skip(by: seconds)
            } else {
                viewModel.togglePlayPause()
            }
        }

        @objc func onPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let t = recognizer.translation(in: view)
            switch recognizer.state {
            case .began:
                panAxis = .undecided
            case .changed:
                if panAxis == .undecided {
                    guard abs(t.y) > 12 || abs(t.x) > 12 else { return }
                    panAxis = abs(t.y) > abs(t.x) ? .vertical : .horizontalIgnored
                    let onLeft = recognizer.location(in: view).x < view.bounds.width / 2
                    panStartLevel = onLeft ? Double(Self.brightness) : Double(PlayerSystemVolume.current)
                }
                guard panAxis == .vertical else { return }
                let onLeft = recognizer.location(in: view).x < view.bounds.width / 2
                let level = panStartLevel + PlayerTouchInput.levelDelta(translationY: t.y, height: view.bounds.height)
                if onLeft { viewModel.setBrightness(CGFloat(level)) } else { viewModel.setVolume(Float(level)) }
            default:
                panAxis = .undecided
            }
        }

        nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        static var brightness: CGFloat {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first?.screen.brightness ?? 0.5
        }
    }
}
#endif
