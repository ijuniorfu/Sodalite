import Foundation
import Testing
@testable import Sodalite

/// What this build writes has to stay readable by the builds already out there. 1.0.0 decodes the
/// playback record synthesized, so every key it declares non-optional must still be emitted; a field
/// retired here is kept on the wire with a constant value rather than dropped.
@Suite("CloudSync stays readable by older decoders", .serialized)
@MainActor
struct CloudSyncOlderDecoderTests {
    /// The non-optional keys of `PlaybackSettingsPayload` at the 1.0.0 tag (`git show 1.0.0:`).
    /// Never remove a key from this list: a shipped decoder does not change.
    private static let requiredBy100: Set<String> = [
        "schemaVersion", "updatedAt", "autoplayNextEpisode", "autoSkipIntro", "autoSkipOutro",
        "nextEpisodeCountdownSeconds", "skipIntervalSeconds", "autoSubtitleForForeignAudio",
        "styledASSSubtitles", "subtitleFontSize", "subtitleColor", "subtitleBackground",
        "subtitleDelaySeconds", "subtitleVerticalPosition", "subtitleFont", "subtitleWeight",
        "pictureMode", "showStatsForNerds", "showEngineDiagnostics", "preferLosslessAudioBridge",
        "showScrubPreview", "preferServerTrickplay", "showDiagnosticOverlay", "focusDiagnosticOverlayOnDV",
    ]

    @Test func thePlaybackRecordCarriesEveryKeyThatOnePointZeroRequires() throws {
        let suite = "olderDecoder.playback"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let container = DependencyContainer(keychainService: InMemoryKeychain(), defaults: defaults)
        let data = try container.collectSettingsPayload(.playback, stamp: .now).encoded()
        let keys = Set(try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)

        #expect(Self.requiredBy100.subtracting(keys).isEmpty, "missing for 1.0.0: \(Self.requiredBy100.subtracting(keys).sorted())")
    }
}
