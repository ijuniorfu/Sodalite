#if os(iOS)
import UIKit

// MARK: - Hardware keyboard (iPad)

/// Space and the arrow keys drive the same transport the touch controls and the Siri Remote drive,
/// so the user's skip interval, the live policy and the scrub preview all apply (AetherEngine #367).
///
/// Claiming them is not optional. AVPlayerViewController carries its own keyboard transport on
/// iPadOS (Space toggles, arrows jump a fixed 15 s), and measurement showed it survives both halves
/// of our AVKit suppression: disabling every AVKit gesture recognizer and hiding the chrome leaves
/// the keys working. That handling drives `self.player` directly, so it ignores the configured skip
/// interval, moves the playhead with no visible chrome to show it, bypasses the view model that owns
/// scrub preview and progress reporting, and does nothing at all on the software (dav1d) path, where
/// there is no AVPlayer bound. Forwarding only the presses we do not handle is what displaces it:
/// AVKit acts on the press reaching `super`, so a swallowed press is a press it never sees.
extension PlayerHostController {

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handleKeyboardKeyDown($0) }
        guard !unhandled.isEmpty else { return }
        super.pressesBegan(unhandled, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handleKeyboardKeyUp($0) }
        guard !unhandled.isEmpty else { return }
        super.pressesEnded(unhandled, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handleKeyboardKeyCancelled($0) }
        guard !unhandled.isEmpty else { return }
        super.pressesCancelled(unhandled, with: event)
    }

    /// Drop a spool that has no key holding it any more (dismissal, backgrounding).
    func endKeyboardTransport() {
        keyboardHoldTask?.cancel()
        keyboardHoldTask = nil
        performKeyboard(keyboardTransport.cancel())
    }

    // MARK: - Edges

    private func handleKeyboardKeyDown(_ press: UIPress) -> Bool {
        guard let key = keyboardTransportKey(for: press) else { return false }
        guard keyboardOwnsTransport else { return keyboardSwallowsPress }
        performKeyboard(keyboardTransport.keyDown(key), holdKey: key)
        return true
    }

    private func handleKeyboardKeyUp(_ press: UIPress) -> Bool {
        guard let key = keyboardTransportKey(for: press) else { return false }
        keyboardHoldTask?.cancel()
        keyboardHoldTask = nil
        guard keyboardOwnsTransport else { return keyboardSwallowsPress }
        performKeyboard(keyboardTransport.keyUp(key))
        return true
    }

    private func handleKeyboardKeyCancelled(_ press: UIPress) -> Bool {
        guard keyboardTransportKey(for: press) != nil else { return false }
        endKeyboardTransport()
        return true
    }

    /// Modifier combinations belong to the system and to menu shortcuts, so only the bare key counts.
    private func keyboardTransportKey(for press: UIPress) -> KeyboardTransportKey? {
        guard let key = press.key, key.modifierFlags.isEmpty else { return nil }
        switch key.keyCode {
        case .keyboardSpacebar: return .space
        case .keyboardLeftArrow: return .leftArrow
        case .keyboardRightArrow: return .rightArrow
        default: return nil
        }
    }

    /// While a menu, prompt or error screen is up the transport is not what these keys should move.
    /// The subtitle search is the exception: it owns a text field, so its presses stay with it.
    private var keyboardOwnsTransport: Bool {
        !viewModel.subtitleSearchVisible
            && !viewModel.isSubtitleDeletePromptVisible
            && !viewModel.isDropdownOpen
            && !viewModel.showStatsOverlay
            && viewModel.errorMessage == nil
    }

    /// Behind an overlay the press is still ours to eat, otherwise AVKit's own handling would seek
    /// the player blind while the user is reading a menu. The subtitle search keeps its keys.
    private var keyboardSwallowsPress: Bool {
        !viewModel.subtitleSearchVisible
    }

    // MARK: - Actions

    private func performKeyboard(_ action: KeyboardTransportAction, holdKey: KeyboardTransportKey? = nil) {
        if action != .none {
            LogTap.shared.note("[Keyboard] \(action)")
        }
        switch action {
        case .togglePlayPause:
            viewModel.togglePlayPause()
        case .armHold(let direction):
            armKeyboardHold(direction: direction, key: holdKey)
        case .beginContinuousSeek(let direction):
            viewModel.beginContinuousSeek(direction: direction)
        case .jump(let direction):
            viewModel.seekJumpByConfiguredInterval(direction: direction)
        case .endContinuousSeek:
            viewModel.endContinuousSeek()
        case .none:
            break
        }
    }

    /// The keyboard gives edges, not gestures, so the hold threshold the remote gets from
    /// `UILongPressGestureRecognizer` is a timer here. It is cancelled by both later edges, so a
    /// press that ends first stays a tap.
    private func armKeyboardHold(direction: Int, key: KeyboardTransportKey?) {
        guard let key else { return }
        keyboardHoldTask?.cancel()
        keyboardHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(KeyboardTransportState.holdThreshold))
            guard !Task.isCancelled, let self else { return }
            self.keyboardHoldTask = nil
            self.performKeyboard(self.keyboardTransport.holdThresholdElapsed(for: key))
        }
    }
}
#endif
