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

    /// Device-observed: on a German device with English audio, iOS asked for the English rendition.
    /// The app's own subtitle language has to win over that.
    @Test("the subtitle language set in the app beats the language the system picked")
    func configuredSubtitleLanguageWins() {
        let streams = [stream(index: 1, lang: "de"), stream(index: 2, lang: "en")]
        #expect(SystemCaptionWindow.resolveTrack(
            streams: streams, requestedLanguage: "en",
            preferredSubtitleLanguage: "de", preferredLanguage: "de", audioLanguage: "en") == 1)
    }

    /// `preferredLanguage` is the app's effective audio language, which falls back to the device
    /// locale, so this is the "my language" case with nothing configured at all.
    @Test("without a configured subtitle language the app's own language wins")
    func appLanguageWinsWhenNothingConfigured() {
        let streams = [stream(index: 1, lang: "de"), stream(index: 2, lang: "en")]
        #expect(SystemCaptionWindow.resolveTrack(
            streams: streams, requestedLanguage: "en",
            preferredSubtitleLanguage: nil, preferredLanguage: "de", audioLanguage: "en") == 1)
    }

    @Test("with nothing in the configured languages the language being heard is used")
    func fallsBackToAudioLanguage() {
        let streams = [stream(index: 1, lang: "en"), stream(index: 2, lang: "fr")]
        #expect(SystemCaptionWindow.resolveTrack(
            streams: streams, requestedLanguage: "fr",
            preferredSubtitleLanguage: "de", preferredLanguage: "de", audioLanguage: "en") == 1)
    }

    @Test("the system's own pick is the last resort, not the first")
    func requestedLanguageIsTheLastResort() {
        let streams = [stream(index: 1, lang: "fr")]
        #expect(SystemCaptionWindow.resolveTrack(
            streams: streams, requestedLanguage: "fr",
            preferredSubtitleLanguage: "de", preferredLanguage: "de", audioLanguage: "en") == 1)
    }

    @Test("nothing matching means nothing is switched on")
    func resolvesToNothing() {
        let streams = [stream(index: 1, lang: "de")]
        #expect(SystemCaptionWindow.resolveTrack(
            streams: streams, requestedLanguage: "fr",
            preferredSubtitleLanguage: nil, preferredLanguage: "ja", audioLanguage: "ja") == nil)
    }

    @Test("a full track beats an SDH or forced one in the chosen language")
    func picksTheMostUsefulTrack() {
        let streams = [
            stream(index: 1, lang: "en", forced: true),
            stream(index: 2, lang: "en", title: "SDH"),
            stream(index: 3, lang: "en")
        ]
        #expect(SystemCaptionWindow.resolveTrack(
            streams: streams, requestedLanguage: nil,
            preferredSubtitleLanguage: "en", preferredLanguage: nil, audioLanguage: nil) == 3)
    }
}
