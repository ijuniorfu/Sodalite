#if os(tvOS)
import SwiftUI
import UIKit

/// The single focusable view left on screen once the Now Playing chrome is hidden (Sodalite#110).
///
/// It exists because of a circularity: hiding the transport is the point of the feature, but the
/// transport was also the only thing holding focus, and the reveal has to read an input from
/// SOMEWHERE. Keeping the buttons around at zero opacity answered that and broke the layout instead,
/// since an invisible view still takes its space and pushed the artwork off centre.
///
/// A sink with nothing beside it is the better answer, and being alone is exactly what makes it work.
/// A directional press is offered to the focus engine first and only falls through to the focused
/// view when no other view consumes it; with no other focusable view there is nothing to consume it,
/// so every direction arrives here, including the edges where a focus move would have had nowhere to
/// go. Indirect touches (a finger moving on the remote's surface, which produces no press at all) are
/// routed to the focused view too, so the pan recogniser catches the swipes presses never describe.
///
/// Menu and Play/Pause are deliberately NOT consumed: Menu still dismisses the cover, and Play/Pause
/// belongs to the screen's own `onPlayPauseCommand`.
struct NowPlayingWakeSink: UIViewRepresentable {
    let wake: () -> Void

    func makeUIView(context: Context) -> WakeSinkView {
        let view = WakeSinkView()
        view.wake = wake
        let pan = UIPanGestureRecognizer(target: view, action: #selector(WakeSinkView.handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: WakeSinkView, context: Context) {
        uiView.wake = wake
    }
}

final class WakeSinkView: UIView {
    var wake: () -> Void = {}

    private static let consumed: Set<UIPress.PressType> = [
        .select, .upArrow, .downArrow, .leftArrow, .rightArrow
    ]

    override var canBecomeFocused: Bool { true }

    @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed: wake()
        default: break
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let mine = presses.filter { Self.consumed.contains($0.type) }
        if !mine.isEmpty { wake() }
        forward(presses.subtracting(mine), with: event, to: super.pressesBegan)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forward(presses.filter { !Self.consumed.contains($0.type) }, with: event, to: super.pressesEnded)
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forward(presses.filter { !Self.consumed.contains($0.type) }, with: event, to: super.pressesChanged)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forward(presses.filter { !Self.consumed.contains($0.type) }, with: event, to: super.pressesCancelled)
    }

    /// Hand the presses this view has no business in back up the chain. Passing an EMPTY set on would
    /// be a UIKit contract violation, so an all-consumed event ends here.
    private func forward(_ presses: Set<UIPress>,
                         with event: UIPressesEvent?,
                         to sup: (Set<UIPress>, UIPressesEvent?) -> Void) {
        guard !presses.isEmpty else { return }
        sup(presses, event)
    }
}
#endif
