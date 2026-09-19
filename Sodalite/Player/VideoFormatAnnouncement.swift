import Foundation
import AetherEngine

/// The lifetime of the dynamic range badge (Sodalite#152).
///
/// The badge used to be drawn under `showControls`, which read as a decision and was not one. It was
/// bounded at five seconds only because the transport was; #93 then made a paused transport unbounded
/// on purpose, and the badge inherited that without anyone choosing it. A paused non-SDR title parked
/// a capsule on the still frame for the length of the pause, on a default install, with no opt-out.
///
/// So the badge gets a lifetime of its own and stops asking the transport anything. It is an
/// announcement: the format arrives, it says so, it goes. The speed badge next to it keeps its
/// persistence for the reason it was given persistence (a viewer at 1.5x who hides the transport must
/// not be silently at the wrong speed); "this is Dolby Vision" carries no equivalent argument for
/// outliving a read. The fact stays retrievable in Stats for Nerds, which has shown the source range
/// all along.
///
/// tvOS only. On iOS the badge sits inside the touch top bar, next to the buttons it was moved under
/// in f28ab58c because a fixed-width capsule starved every row it shared on a narrow phone. There it
/// is chrome: it lives and dies with the bar, one tap on the picture takes both away, and the top
/// right it would have to float in is already occupied.
enum VideoFormatAnnouncement {
    /// Five seconds, which is also what the transport's auto-hide runs on, and deliberately not read
    /// from it. Sharing that constant is how the badge ended up borrowing the transport's lifetime in
    /// the first place; the two are unrelated questions that happen to have the same answer.
    static let window: Duration = .seconds(5)

    /// A format worth announcing is one that is news and is not SDR.
    ///
    /// `to == .sdr` covers the episode seam as well as plain SDR content: `PlayerViewModel+NextEpisode`
    /// resets the format to `.sdr` before the next title is probed, and that reset must not flash
    /// anything. The engine's answer for the new episode arrives as `.sdr -> X` and announces there.
    static func announces(from old: VideoFormat, to new: VideoFormat) -> Bool {
        new != .sdr && new != old
    }
}
