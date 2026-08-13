import Foundation

/// The three hardware-keyboard keys the iPad player claims. Everything else is not ours and goes
/// back up the responder chain (AetherEngine #367).
enum KeyboardTransportKey: Equatable {
    case space
    case leftArrow
    case rightArrow

    var seekDirection: Int? {
        switch self {
        case .space: return nil
        case .leftArrow: return -1
        case .rightArrow: return 1
        }
    }
}

/// What a key edge means for the transport. The host translates these into `PlayerViewModel` calls,
/// so the same jump interval, live policy and scrub preview the Siri Remote and the touch controls
/// use apply to the keyboard too.
enum KeyboardTransportAction: Equatable {
    case togglePlayPause
    /// Start the hold timer for this direction; the press is still ambiguous between tap and hold.
    case armHold(direction: Int)
    case beginContinuousSeek(direction: Int)
    case jump(direction: Int)
    case endContinuousSeek
    case none
}

/// Tap-versus-hold resolution for the keyboard, kept out of the responder so it can be tested.
///
/// A hardware keyboard gives two edges and no gesture recognizer, so the ambiguity the Siri Remote
/// resolves with a `UILongPressGestureRecognizer` is resolved here: the down edge only arms a timer,
/// and the meaning of the press is decided by whichever comes first, the threshold or the up edge.
struct KeyboardTransportState {

    /// Same threshold as the remote's `addHoldGesture`, so a hold feels identical on both inputs.
    static let holdThreshold: Double = 0.35

    private var heldKey: KeyboardTransportKey?
    private var isSpooling = false

    init() {}

    mutating func keyDown(_ key: KeyboardTransportKey) -> KeyboardTransportAction {
        guard let direction = key.seekDirection else { return .togglePlayPause }
        // Auto-repeat, or the other arrow arriving mid-hold: one press owns the spool until it ends.
        guard heldKey == nil else { return .none }
        heldKey = key
        return .armHold(direction: direction)
    }

    mutating func holdThresholdElapsed(for key: KeyboardTransportKey) -> KeyboardTransportAction {
        guard heldKey == key, !isSpooling, let direction = key.seekDirection else { return .none }
        isSpooling = true
        return .beginContinuousSeek(direction: direction)
    }

    mutating func keyUp(_ key: KeyboardTransportKey) -> KeyboardTransportAction {
        guard let direction = key.seekDirection else { return .none }
        guard heldKey == key else { return .none }
        heldKey = nil
        if isSpooling {
            isSpooling = false
            return .endContinuousSeek
        }
        return .jump(direction: direction)
    }

    /// The press went away without a release (dismissal, backgrounding, `pressesCancelled`).
    mutating func cancel() -> KeyboardTransportAction {
        heldKey = nil
        guard isSpooling else { return .none }
        isSpooling = false
        return .endContinuousSeek
    }
}
