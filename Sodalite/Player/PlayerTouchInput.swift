#if os(iOS)
import UIKit

/// Owns the screen-wide touch recognizers on the player host and maps them to view-model intents:
/// single-tap toggles controls, double-tap on the left/right third skips +/-10s (middle = play/pause),
/// a vertical pan changes brightness (left half) or volume (right half). It draws no UI; the transport
/// controls and the scrubber are handled in SwiftUI. The pure mappers are static for unit testing.
@MainActor
final class PlayerTouchInput: NSObject {
    private weak var host: UIView?
    private let viewModel: PlayerViewModel
    private let skipInterval: Double = 10

    private enum PanAxis { case undecided, vertical, horizontalIgnored }
    private var panAxis: PanAxis = .undecided
    private var panStartLevel: Double = 0

    init(host: UIView, viewModel: PlayerViewModel) {
        self.host = host
        self.viewModel = viewModel
        super.init()

        let single = UITapGestureRecognizer(target: self, action: #selector(onSingleTap(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        for recognizer in [single, double, pan] {
            recognizer.delegate = self
            host.addGestureRecognizer(recognizer)
        }
    }

    // MARK: - Pure mappers (unit-tested)

    /// Left third -> -interval, right third -> +interval, middle -> nil (handled as play/pause).
    static func skipSeconds(forTapX x: CGFloat, width: CGFloat, interval: Double) -> Double? {
        guard width > 0 else { return nil }
        if x < width / 3 { return -interval }
        if x > width * 2 / 3 { return interval }
        return nil
    }

    /// Upward drag raises the level. Returned delta is a 0...1-scaled fraction of the drag height.
    static func levelDelta(translationY: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return Double(-translationY / height)
    }

    // MARK: - Recognizer handlers

    @objc private func onSingleTap(_ recognizer: UITapGestureRecognizer) {
        if viewModel.showControls { viewModel.hideControls() }
        else { viewModel.showControlsTemporarily() }
    }

    @objc private func onDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let host else { return }
        let x = recognizer.location(in: host).x
        if let seconds = Self.skipSeconds(forTapX: x, width: host.bounds.width, interval: skipInterval) {
            viewModel.skip(by: seconds)
        } else {
            viewModel.togglePlayPause()
        }
    }

    @objc private func onPan(_ recognizer: UIPanGestureRecognizer) {
        guard let host else { return }
        let translation = recognizer.translation(in: host)
        switch recognizer.state {
        case .began:
            panAxis = .undecided
        case .changed:
            if panAxis == .undecided {
                guard abs(translation.y) > 12 || abs(translation.x) > 12 else { return }
                panAxis = abs(translation.y) > abs(translation.x) ? .vertical : .horizontalIgnored
                let onLeft = recognizer.location(in: host).x < host.bounds.width / 2
                panStartLevel = onLeft
                    ? Double((UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }.first?.screen.brightness) ?? 0.5)
                    : Double(PlayerSystemVolume.current)
            }
            guard panAxis == .vertical else { return }
            let onLeft = recognizer.location(in: host).x < host.bounds.width / 2
            let level = panStartLevel + Self.levelDelta(translationY: translation.y, height: host.bounds.height)
            if onLeft { viewModel.setBrightness(CGFloat(level)) }
            else { viewModel.setVolume(Float(level)) }
        default:
            panAxis = .undecided
        }
    }
}

extension PlayerTouchInput: UIGestureRecognizerDelegate {
    // Coexist with the SwiftUI scrubber/button gestures, which sit above in the overlay and win their hits.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
