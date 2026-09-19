import AVFoundation
import Foundation

/// Where a session's picture is, once it has left this device's own layer (Sodalite#156).
///
/// The wired case carries no name on purpose: an HDMI adapter reports its audio port as "HDMI", which
/// is a cable, not a destination anyone recognises. The same case absorbs the theoretical route that
/// engages external playback without naming a port at all.
enum ExternalPlaybackDestination: Equatable {
    case airPlay(name: String?)
    case externalDisplay
}

/// The rules for the iOS player's remote view: the screen it puts up while the picture plays somewhere
/// else, and which controls stand down for the duration (Sodalite#156).
///
/// Pure and platform neutral so the gating is testable without a route or a window, matching
/// `ExternalSubtitleWindowDecision` and the engine's decision types.
enum ExternalPlaybackPresentation {
    /// How long a dropped `isExternalPlaybackActive` is held before the remote view steps down.
    ///
    /// AVPlayer reports a transient `false` in the middle of every session-preserving reload (next
    /// episode, audio switch): the reload tears down the very item the KVO watches. The engine holds
    /// that edge for its own reload (AetherEngine #227, `externalPlaybackEdgeHeld`); here the same edge
    /// would blink the remote view away and back on each episode change. Held only in this direction:
    /// engaging is always immediate, and the subtitle routing keeps reading the raw flag, so nothing
    /// load-bearing is delayed.
    ///
    /// Deliberately NOT latched on the audio route the way the engine's `externalPlaybackHoldsThePicture`
    /// does it. AirPlay speakers (a HomePod) put the route on `.airPlay` while the picture stays on the
    /// phone, and that would read as casting for a viewer who is watching the device in their hand.
    static let dropGrace: Duration = .milliseconds(1500)

    /// Names the destination from the audio route, asked only while external playback is engaged.
    ///
    /// Wired wins over wireless: an Apple TV reached over a cable exposes both ports on some adapters,
    /// and the wired one is what actually carries the picture. Same precedence as the engine's
    /// `isWiredHDMIExternalDisplay` discriminator, which decides the LAN reload on the other side.
    static func destination(ports: [(type: AVAudioSession.Port, name: String)]) -> ExternalPlaybackDestination {
        if ports.contains(where: { $0.type == .HDMI }) { return .externalDisplay }
        guard let wireless = ports.first(where: { $0.type == .airPlay }) else { return .externalDisplay }
        return .airPlay(name: displayName(forPort: wireless.name))
    }

    /// A receiver's own name, or nil where the port only repeats the protocol. "AirPlay" as a device
    /// name would render as "Playing on AirPlay".
    static func displayName(forPort name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("AirPlay") != .orderedSame else { return nil }
        return trimmed
    }

    /// Whether the controls that act on this device's own video layer still mean anything.
    ///
    /// False while the picture is elsewhere, which stands down the picture-mode button (it sets
    /// `videoGravity` on a layer nobody is looking at) and the brightness swipe (it dims a screen that
    /// is showing artwork). The volume swipe is NOT on this list: an AirPlay 2 receiver takes the
    /// device's system volume, so it is the one edge gesture that still reaches the viewer's ears.
    static func localPictureControlsApply(destination: ExternalPlaybackDestination?) -> Bool {
        destination == nil
    }

    /// Whether the transport's idle auto-hide may fire.
    ///
    /// It may not while the picture is elsewhere: hiding the controls would reveal nothing, because
    /// there is no picture underneath to look at, only the remote view's own artwork.
    static func autoHideApplies(destination: ExternalPlaybackDestination?) -> Bool {
        destination == nil
    }
}
