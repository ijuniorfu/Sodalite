import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// Sodalite#65: iOS turns captions on by itself when playback is muted. The engine reports that as
/// a `SystemCaptionRequest` and the app answers it with its own subtitles; this type owns the
/// policy so it stays testable without an engine.
@MainActor
struct SystemCaptionWindowTests {

    private func stream(index: Int, codec: String? = "subrip", lang: String? = "en",
                        title: String? = nil, forced: Bool? = nil) -> MediaStream {
        MediaStream(index: index, type: .subtitle, codec: codec, language: lang,
                    displayTitle: nil, title: title, isDefault: nil, isForced: forced,
                    isExternal: false, height: nil, width: nil, channels: nil,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    // MARK: - Opening

    @Test("a request while the output is muted opens the window")
    func opensWhenMuted() {
        #expect(SystemCaptionWindow.shouldOpen(subtitlesActive: false, volume: 0))
    }

    @Test("a very low volume still counts as muted")
    func opensWhenVeryQuiet() {
        #expect(SystemCaptionWindow.shouldOpen(subtitlesActive: false, volume: 0.1))
    }

    /// The skip-back and language-mismatch triggers arrive through the same signal; they are
    /// answered elsewhere and must not switch a second track on here.
    @Test("a request at normal volume belongs to another trigger and is ignored")
    func ignoresRequestAtAudibleVolume() {
        #expect(!SystemCaptionWindow.shouldOpen(subtitlesActive: false, volume: 0.4))
    }

    @Test("a running subtitle is left alone")
    func ignoresRequestWhileSubtitlesRun() {
        #expect(!SystemCaptionWindow.shouldOpen(subtitlesActive: true, volume: 0))
    }

    // MARK: - Closing

    @Test("the window closes as soon as the output is audible again")
    func closesWhenAudible() {
        let state = SystemCaptionWindow.State(streamIndex: 3)
        #expect(SystemCaptionWindow.shouldClose(state: state, volume: 0.2))
    }

    @Test("the window stays open while the output is still muted")
    func staysOpenWhileMuted() {
        let state = SystemCaptionWindow.State(streamIndex: 3)
        #expect(!SystemCaptionWindow.shouldClose(state: state, volume: 0))
        #expect(!SystemCaptionWindow.shouldClose(state: state, volume: 0.05))
    }

    @Test("no window, nothing to close")
    func nothingToCloseWithoutState() {
        #expect(!SystemCaptionWindow.shouldClose(state: nil, volume: 1))
    }

    // MARK: - Track resolution

    @Test("the language the system picked wins over the app's own resolution")
    func requestedLanguageWins() {
        let streams = [stream(index: 1, lang: "de"), stream(index: 2, lang: "en")]
        #expect(SystemCaptionWindow.resolveTrack(
            streams: streams, requestedLanguage: "en",
            preferredSubtitleLanguage: "de", audioLanguage: "de") == 2)
    }

    @Test("an untagged rendition falls back to the app's own resolution")
    func untaggedRequestFallsBack() {
        let streams = [stream(index: 1, lang: "de"), stream(index: 2, lang: "en")]
        #expect(SystemCaptionWindow.resolveTrack(
            streams: streams, requestedLanguage: nil,
            preferredSubtitleLanguage: "de", audioLanguage: "en") == 1)
    }

    @Test("a language with no matching track falls back to the app's own resolution")
    func unmatchedLanguageFallsBack() {
        let streams = [stream(index: 1, lang: "de")]
        #expect(SystemCaptionWindow.resolveTrack(
            streams: streams, requestedLanguage: "fr",
            preferredSubtitleLanguage: nil, audioLanguage: "de") == 1)
    }

    @Test("nothing matching means nothing is switched on")
    func resolvesToNothing() {
        let streams = [stream(index: 1, lang: "de")]
        #expect(SystemCaptionWindow.resolveTrack(
            streams: streams, requestedLanguage: "fr",
            preferredSubtitleLanguage: nil, audioLanguage: "ja") == nil)
    }

    @Test("a full track beats an SDH or forced one in the picked language")
    func picksTheMostUsefulTrack() {
        let streams = [
            stream(index: 1, lang: "en", forced: true),
            stream(index: 2, lang: "en", title: "SDH"),
            stream(index: 3, lang: "en")
        ]
        #expect(SystemCaptionWindow.resolveTrack(
            streams: streams, requestedLanguage: "en",
            preferredSubtitleLanguage: nil, audioLanguage: nil) == 3)
    }
}
