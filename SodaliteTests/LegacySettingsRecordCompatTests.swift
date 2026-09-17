import Foundation
import Testing
@testable import Sodalite

/// `PlaybackSettingsPayload` as it is on `main` on 2026-09-17, frozen. Synthesized Decodable, so every
/// non-Optional field is a key a pre-change build requires.
private struct PreChangePlaybackSettingsPayload: Decodable {
    var schemaVersion: Int
    var updatedAt: Date
    var autoplayNextEpisode: Bool
    var autoSkipIntro: Bool
    var autoSkipOutro: Bool
    var nextEpisodeCountdownSeconds: Int
    var skipIntervalSeconds: Int
    var preferredAudioLanguage: String?
    var preferredSubtitleLanguage: String?
    var autoSubtitleForForeignAudio: Bool
    var styledASSSubtitles: Bool
    var subtitleFontSize: String
    var subtitleColor: String
    var subtitleBackground: String
    var subtitleDelaySeconds: Double
    var subtitleVerticalPosition: String
    var subtitleFont: String
    var subtitleWeight: String
    var pictureMode: String
    var showStatsForNerds: Bool
    var showEngineDiagnostics: Bool
    var preferLosslessAudioBridge: Bool
    var showScrubPreview: Bool
    var preferServerTrickplay: Bool
    var playerRotationLocked: Bool?
    var networkBufferDepth: String?
    var rememberTrackSelections: Bool?
    var autoForcedSubtitles: Bool?
    var autoSkipRecap: Bool?
    var subtitlesOnSkipBack: Bool?
    var liveTeletextPage: String?
    var liveBufferDepth: String?
    var autoplayCountdown: Bool?
    var forceDolbyVisionOnNonDVDisplay: Bool?
    var touchpadScrubbing: Bool?
    var nextEpisodeCountdownAnchor: String?
    var skipForwardSeconds: Int?
    var skipBackwardSeconds: Int?
}

/// `AppearanceSettingsPayload` on `main` on 2026-09-17 decodes every other field with
/// `decodeIfPresent`, so these are the keys it requires.
private struct PreChangeAppearanceSettingsPayload: Decodable {
    var updatedAt: Date
    var accentChoice: String
    var showContentLogos: Bool
    var continueWatchingImage: String
    var largeCards: Bool
    var nowPlayingUsesSeriesPoster: Bool
}

@Suite("Legacy settings records stay readable for pre-change builds", .serialized)
@MainActor
struct LegacySettingsRecordCompatTests {
    @Test func aPreChangeBuildDecodesTheLegacyRecordsThisBuildWrites() throws {
        let suite = "legacyCompat.\(UUID().uuidString)"
        let container = DependencyContainer(keychainService: InMemoryKeychain(), defaults: UserDefaults(suiteName: suite)!)
        let alice = ProfileKey(serverID: "compat-\(UUID().uuidString)", userID: "alice")
        container.profileSettings.migrateIfNeeded(profiles: [alice])
        container.profileSettings.settings(for: alice).playback.preferredAudioLanguage = "ger"
        container.profileSettings.settings(for: alice).appearance.largeCards = true

        let playback = try container.collectSettingsPayload(.playback, stamp: .now, profile: alice).encoded()
        let appearance = try container.collectSettingsPayload(.appearance, stamp: .now, profile: alice).encoded()

        #expect(try JSONDecoder().decode(PreChangePlaybackSettingsPayload.self, from: playback).preferredAudioLanguage == "ger")
        #expect(try JSONDecoder().decode(PreChangeAppearanceSettingsPayload.self, from: appearance).largeCards)
    }
}
