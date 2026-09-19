import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// Sodalite#152: the format badge had no lifetime of its own, it borrowed the transport's.
///
/// It was drawn under `showControls`, which was bounded at five seconds until #93 deliberately made a
/// paused transport unbounded. The badge inherited that and sat on the paused frame for the length of
/// the pause, for every user, with no setting to turn it off. Nothing ever decided the badge should be
/// unbounded, so the fix is not a second condition on the transport rule but a window the badge owns.
struct VideoFormatBadgeLifetimeTests {

    // MARK: - When the badge speaks

    @Test("A non-SDR format announces itself once it is known")
    func aNonSDRFormatAnnouncesItself() {
        #expect(VideoFormatAnnouncement.announces(from: .sdr, to: .dolbyVision))
        #expect(VideoFormatAnnouncement.announces(from: .sdr, to: .hdr10))
        #expect(VideoFormatAnnouncement.announces(from: .sdr, to: .hdr10Plus))
        #expect(VideoFormatAnnouncement.announces(from: .sdr, to: .hlg))
    }

    /// The engine discovers HDR10+ from a T.35 SEI that can arrive well after the demuxer probe, and a
    /// Dolby Vision profile can be rewritten mid-session. A viewer who watched the badge say HDR10 an
    /// hour ago is owed the correction, so a change between two non-SDR formats speaks again.
    @Test("A mid-stream format change announces again")
    func aMidStreamChangeAnnouncesAgain() {
        #expect(VideoFormatAnnouncement.announces(from: .hdr10, to: .hdr10Plus))
        #expect(VideoFormatAnnouncement.announces(from: .dolbyVision, to: .hdr10))
    }

    // MARK: - When it stays quiet

    /// SDR has never had a badge and does not get one here. This also covers the episode seam, where
    /// `PlayerViewModel+NextEpisode` resets the format to `.sdr` before the next title is probed: the
    /// reset itself must not flash a badge, the engine's answer for the new episode does.
    @Test("SDR never announces, including the reset at an episode seam")
    func sdrNeverAnnounces() {
        #expect(!VideoFormatAnnouncement.announces(from: .sdr, to: .sdr))
        #expect(!VideoFormatAnnouncement.announces(from: .dolbyVision, to: .sdr))
        #expect(!VideoFormatAnnouncement.announces(from: .hlg, to: .sdr))
    }

    /// The publisher can re-emit the same value; a redundant emission is not news.
    @Test("An unchanged format does not restart the window")
    func anUnchangedFormatDoesNotAnnounce() {
        #expect(!VideoFormatAnnouncement.announces(from: .dolbyVision, to: .dolbyVision))
        #expect(!VideoFormatAnnouncement.announces(from: .hdr10Plus, to: .hdr10Plus))
    }

    // MARK: - How long it stays

    /// Five seconds, the same number the transport runs on, but deliberately a constant of its own:
    /// the coupling to the transport is the bug. The two are free to diverge and neither reads the
    /// other.
    @Test("The badge owns its window")
    func theBadgeOwnsItsWindow() {
        #expect(VideoFormatAnnouncement.window == .seconds(5))
    }

    // MARK: - That the transport no longer moves it

    /// The regression this file exists to prevent: re-hanging the badge off control visibility. A
    /// policy test cannot see the view, so this one reads it.
    @Test("The tvOS badge is not drawn from control visibility")
    func theBadgeDoesNotReadTheTransport() throws {
        let source = try sourceFile("Sodalite/Player/UI/PlayerOverlayView.swift")
        #expect(source.contains("announcedVideoFormat"))
        #expect(!source.contains("showControls && viewModel.videoFormat"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
