import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// Sodalite#63: a backward jump temporarily switches subtitles on until playback reaches the
/// position the jump started from. This type owns the policy so it stays testable without an engine.
@MainActor
struct SkipBackSubtitleWindowTests {

    private func stream(index: Int, codec: String? = "subrip", lang: String? = "en",
                        title: String? = nil, forced: Bool? = nil) -> MediaStream {
        MediaStream(index: index, type: .subtitle, codec: codec, language: lang,
                    displayTitle: nil, title: title, isDefault: nil, isForced: forced,
                    isExternal: false, height: nil, width: nil, channels: nil,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    // MARK: - Origin of a press burst

    @Test("a second backward jump keeps the position the user actually left")
    func burstKeepsFurthestOrigin() {
        #expect(SkipBackSubtitleWindow.mergedOrigin(100, 90) == 100)
    }

    @Test("the first press of a burst takes the current playhead")
    func firstPressTakesPlayhead() {
        #expect(SkipBackSubtitleWindow.mergedOrigin(nil, 90) == 90)
    }

    // MARK: - Opening

    @Test("a backward jump with subtitles off opens the window")
    func opensOnBackwardJump() {
        #expect(SkipBackSubtitleWindow.shouldOpen(
            pendingOrigin: 100, targetTime: 90, subtitlesActive: false, enabled: true))
    }

    @Test("a running subtitle is left alone")
    func doesNotOpenWhileSubtitlesRun() {
        #expect(!SkipBackSubtitleWindow.shouldOpen(
            pendingOrigin: 100, targetTime: 90, subtitlesActive: true, enabled: true))
    }

    @Test("the preference gates the window")
    func doesNotOpenWhenDisabled() {
        #expect(!SkipBackSubtitleWindow.shouldOpen(
            pendingOrigin: 100, targetTime: 90, subtitlesActive: false, enabled: false))
    }

    /// A pan or hold-to-seek never records an origin, so its commit must not open a window.
    @Test("a commit without a recorded origin opens nothing")
    func doesNotOpenWithoutOrigin() {
        #expect(!SkipBackSubtitleWindow.shouldOpen(
            pendingOrigin: nil, targetTime: 90, subtitlesActive: false, enabled: true))
    }

    /// Skipping back at the very start clamps to 0 and can land where it started.
    @Test("a jump that does not actually move back opens nothing")
    func doesNotOpenOnZeroDistance() {
        #expect(!SkipBackSubtitleWindow.shouldOpen(
            pendingOrigin: 0.2, targetTime: 0, subtitlesActive: false, enabled: true))
    }

    // MARK: - Closing

    @Test("the window closes once playback reaches the origin")
    func closesAtOrigin() {
        let state = SkipBackSubtitleWindow.State(origin: 100, streamIndex: 3)
        #expect(SkipBackSubtitleWindow.shouldClose(state: state, playhead: 100))
        #expect(SkipBackSubtitleWindow.shouldClose(state: state, playhead: 101))
    }

    @Test("the window stays open short of the origin")
    func staysOpenBeforeOrigin() {
        let state = SkipBackSubtitleWindow.State(origin: 100, streamIndex: 3)
        #expect(!SkipBackSubtitleWindow.shouldClose(state: state, playhead: 99.5))
    }

    @Test("no window, nothing to close")
    func nothingToCloseWithoutState() {
        #expect(!SkipBackSubtitleWindow.shouldClose(state: nil, playhead: 100))
    }

    // MARK: - Track resolution

    @Test("the preferred subtitle language wins")
    func preferredLanguageWins() {
        let streams = [stream(index: 2, lang: "en"), stream(index: 3, lang: "de")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: "de", audioLanguage: "eng") == 3)
    }

    /// The case applyPreferredSubtitle refuses to handle: audio is already in the user's language,
    /// which is exactly when someone asks "what did they say?".
    @Test("without a preferred language the audio language is used")
    func fallsBackToAudioLanguage() {
        let streams = [stream(index: 2, lang: "en"), stream(index: 3, lang: "de")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: nil, audioLanguage: "eng") == 2)
    }

    @Test("a preferred language with no track falls through to the audio language")
    func preferredMissingFallsThrough() {
        let streams = [stream(index: 2, lang: "en")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: "es", audioLanguage: "eng") == 2)
    }

    @Test("nothing matching means nothing is switched on")
    func noBlindFirstPick() {
        let streams = [stream(index: 2, lang: "th")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: nil, audioLanguage: "eng") == nil)
    }

    @Test("a full track beats SDH and forced ones")
    func fullTrackWinsOverSDHAndForced() {
        let streams = [stream(index: 2, lang: "en", forced: true),
                       stream(index: 3, lang: "en", title: "English SDH"),
                       stream(index: 4, lang: "en")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: nil, audioLanguage: "en") == 4)
    }

    @Test("text beats bitmap at equal descriptor rank")
    func textBeatsBitmap() {
        let streams = [stream(index: 2, codec: "hdmv_pgs_subtitle", lang: "en"),
                       stream(index: 3, codec: "subrip", lang: "en")]
        #expect(SkipBackSubtitleWindow.resolveTrack(
            streams: streams, preferredSubtitleLanguage: nil, audioLanguage: "en") == 3)
    }
}
