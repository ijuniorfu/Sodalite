import Foundation
import CoreGraphics
import Observation
import AetherEngine

/// Device-local (UserDefaults) playback tuning; read/write via `DependencyContainer.playbackPreferences`.
@Observable
@MainActor
final class PlaybackPreferences {

    // MARK: - Keys

    private enum Keys {
        static let autoplayNextEpisode = "playback.autoplayNextEpisode"
        static let nextEpisodeCountdownSeconds = "playback.nextEpisodeCountdownSeconds"
        static let skipIntervalSeconds = "playback.skipIntervalSeconds"
        static let preferredAudioLanguage = "playback.preferredAudioLanguage"
        static let preferredSubtitleLanguage = "playback.preferredSubtitleLanguage"
        static let autoSkipIntro = "playback.autoSkipIntro"
        static let autoSkipOutro = "playback.autoSkipOutro"
        static let autoSubtitleForForeignAudio = "playback.autoSubtitleForForeignAudio"
        static let styledASSSubtitles = "playback.styledASSSubtitles"
        static let subtitleFontSize = "playback.subtitleFontSize"
        static let subtitleColor = "playback.subtitleColor"
        static let subtitleBackground = "playback.subtitleBackground"
        /// v2 versioned key; read first, else migrate legacy v1 (legacy "none" -> .shadow).
        static let subtitleBackgroundV2 = "playback.subtitleBackgroundV2"
        static let subtitleDelaySeconds = "playback.subtitleDelaySeconds"
        /// Legacy ±200 pt slider, superseded by SubtitleVerticalPosition; not migrated.
        static let subtitleVerticalOffsetPoints = "playback.subtitleVerticalOffsetPoints"
        static let subtitleVerticalPosition = "playback.subtitleVerticalPosition"
        static let subtitleFont = "playback.subtitleFont"
        static let subtitleWeight = "playback.subtitleWeight"
        static let pictureMode = "playback.pictureMode"
        static let showStatsForNerds = "playback.showStatsForNerds"
        static let showEngineDiagnostics = "playback.showEngineDiagnostics"
        static let showDiagnosticOverlay = "playback.showDiagnosticOverlay"
        static let focusDiagnosticOverlayOnDV = "playback.focusDiagnosticOverlayOnDV"
        static let preferLosslessAudioBridge = "playback.preferLosslessAudioBridge"
        static let showScrubPreview = "playback.showScrubPreview"
        static let preferServerTrickplay = "playback.preferServerTrickplay"
        static let playerRotationLocked = "playback.playerRotationLocked"
    }

    // MARK: - Allowed Values

    static let skipIntervalChoices: [Int] = [5, 10, 15, 30]

    /// Negative shifts subs earlier, positive later; finer steps near zero.
    static let subtitleDelayChoices: [Double] = [
        -5, -3, -2, -1.5, -1, -0.5, -0.25, 0, 0.25, 0.5, 1, 1.5, 2, 3, 5
    ]

    // Legacy ±200 pt slider replaced by SubtitleVerticalPosition; no migration: ambiguous pt-to-fraction math on the asymmetric new scale.

    /// Alphabetical; ISO 639-2/B bibliographic codes, Jellyfin convention "deu" not "ger".
    private static let baseLanguages: [LanguageChoice] = [
        LanguageChoice(code: "ara", short: "AR",  titleKey: "settings.playback.language.ara"),
        LanguageChoice(code: "chi", short: "ZH",  titleKey: "settings.playback.language.zho"),
        LanguageChoice(code: "cze", short: "CS",  titleKey: "settings.playback.language.ces"),
        LanguageChoice(code: "dan", short: "DA",  titleKey: "settings.playback.language.dan"),
        LanguageChoice(code: "dut", short: "NL",  titleKey: "settings.playback.language.nld"),
        LanguageChoice(code: "eng", short: "EN",  titleKey: "settings.playback.language.eng"),
        LanguageChoice(code: "fin", short: "FI",  titleKey: "settings.playback.language.fin"),
        LanguageChoice(code: "fre", short: "FR",  titleKey: "settings.playback.language.fra"),
        LanguageChoice(code: "ger", short: "DE",  titleKey: "settings.playback.language.deu"),
        LanguageChoice(code: "gre", short: "EL",  titleKey: "settings.playback.language.ell"),
        LanguageChoice(code: "heb", short: "HE",  titleKey: "settings.playback.language.heb"),
        LanguageChoice(code: "hin", short: "HI",  titleKey: "settings.playback.language.hin"),
        LanguageChoice(code: "hun", short: "HU",  titleKey: "settings.playback.language.hun"),
        LanguageChoice(code: "ind", short: "ID",  titleKey: "settings.playback.language.ind"),
        LanguageChoice(code: "ita", short: "IT",  titleKey: "settings.playback.language.ita"),
        LanguageChoice(code: "jpn", short: "JA",  titleKey: "settings.playback.language.jpn"),
        LanguageChoice(code: "kor", short: "KO",  titleKey: "settings.playback.language.kor"),
        LanguageChoice(code: "nor", short: "NO",  titleKey: "settings.playback.language.nor"),
        LanguageChoice(code: "pol", short: "PL",  titleKey: "settings.playback.language.pol"),
        LanguageChoice(code: "por", short: "PT",  titleKey: "settings.playback.language.por"),
        LanguageChoice(code: "rum", short: "RO",  titleKey: "settings.playback.language.ron"),
        LanguageChoice(code: "rus", short: "RU",  titleKey: "settings.playback.language.rus"),
        LanguageChoice(code: "spa", short: "ES",  titleKey: "settings.playback.language.spa"),
        LanguageChoice(code: "swe", short: "SV",  titleKey: "settings.playback.language.swe"),
        LanguageChoice(code: "tha", short: "TH",  titleKey: "settings.playback.language.tha"),
        LanguageChoice(code: "tur", short: "TR",  titleKey: "settings.playback.language.tur"),
        LanguageChoice(code: "ukr", short: "UK",  titleKey: "settings.playback.language.ukr"),
        LanguageChoice(code: "vie", short: "VI",  titleKey: "settings.playback.language.vie"),
    ]

    static var audioLanguageChoices: [LanguageChoice] {
        [LanguageChoice(code: nil, short: "Auto", titleKey: "settings.playback.language.auto")]
            + baseLanguages
    }

    /// "Auto" first; nil code lets per-track auto-pick decide, an explicit code pins it.
    static var subtitleLanguageChoices: [LanguageChoice] {
        [LanguageChoice(code: nil, short: "Auto", titleKey: "settings.playback.language.auto")]
            + baseLanguages
    }

    struct LanguageChoice: Hashable, Sendable {
        /// ISO 639-2/B code (Jellyfin convention "deu"), or nil for stream default.
        let code: String?
        let short: String
        let titleKey: String
    }

    /// Sizes calibrated for tvOS viewing distance, ~32 pt (small) to ~68 pt (xlarge).
    enum SubtitleFontSize: String, CaseIterable, Sendable, Identifiable {
        case small, medium, large, xlarge
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.size.\(rawValue)" }
        /// Multiplier on the 28 pt base, geometric growth so each step reads distinctly bigger.
        var scale: CGFloat {
            switch self {
            case .small: return 1.15
            case .medium: return 1.45
            case .large: return 1.85
            case .xlarge: return 2.4
            }
        }
    }

    enum SubtitleColor: String, CaseIterable, Sendable, Identifiable {
        case white, yellow, gray
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.color.\(rawValue)" }
    }

    /// .shadow preserves old .none misnomer behavior (shadow was always there) so no visual change after case split; .none is now truly naked text.
    enum SubtitleBackground: String, CaseIterable, Sendable, Identifiable {
        case box, outline, shadow, none
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.background.\(rawValue)" }
    }

    /// Downward-only fraction-of-player-rect steps, no negative half; explicit `default` opt-out matters for PGS/DVB/DVD source-baked positions.
    enum SubtitleVerticalPosition: String, CaseIterable, Sendable, Identifiable {
        case `default`
        case bottom
        case step1
        case step2
        case step3

        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.position.\(rawValue)" }

        /// Fraction of player rect height from bottom edge; nil = no override (historical baseline, bitmap cues untouched).
        var fractionFromBottom: Double? {
            switch self {
            case .default: return nil
            case .bottom:  return 0.005
            case .step1:   return 0.10
            case .step2:   return 0.20
            case .step3:   return 0.30
            }
        }
    }

    /// highLegibility = bundled Atkinson Hyperlegible; text cues only, bitmap cues ignore it.
    enum SubtitleFont: String, CaseIterable, Sendable, Identifiable {
        case system, highLegibility
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.font.\(rawValue)" }
    }

    /// Text cues only; bitmap cues are pre-rendered and ignore weight.
    enum SubtitleWeight: String, CaseIterable, Sendable, Identifiable {
        case regular, bold
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.weight.\(rawValue)" }
    }

    /// `original` keeps aspect ratio (letterbox), `fill` crops to cover; maps to AVLayerVideoGravity in the engine.
    enum PictureMode: String, CaseIterable, Sendable, Identifiable {
        case original, fill
        var id: String { rawValue }
        var titleKey: String { "settings.playback.picture.\(rawValue)" }
    }

    // MARK: - Properties

    var autoplayNextEpisode: Bool {
        didSet { store.set(autoplayNextEpisode, forKey: Keys.autoplayNextEpisode) }
    }

    var autoSkipIntro: Bool {
        didSet { store.set(autoSkipIntro, forKey: Keys.autoSkipIntro) }
    }

    var autoSkipOutro: Bool {
        didSet { store.set(autoSkipOutro, forKey: Keys.autoSkipOutro) }
    }

    var nextEpisodeCountdownSeconds: Int {
        didSet { store.set(nextEpisodeCountdownSeconds, forKey: Keys.nextEpisodeCountdownSeconds) }
    }

    var skipIntervalSeconds: Int {
        didSet { store.set(skipIntervalSeconds, forKey: Keys.skipIntervalSeconds) }
    }

    var preferredAudioLanguage: String? {
        didSet { store.set(preferredAudioLanguage, forKey: Keys.preferredAudioLanguage) }
    }

    var preferredSubtitleLanguage: String? {
        didSet { store.set(preferredSubtitleLanguage, forKey: Keys.preferredSubtitleLanguage) }
    }

    /// Auto-enable subs when audio isn't in preferred language; default ON per streaming-app convention.
    var autoSubtitleForForeignAudio: Bool {
        didSet { store.set(autoSubtitleForForeignAudio, forKey: Keys.autoSubtitleForForeignAudio) }
    }

    /// Render ASS/SSA with authored styling via libass; OFF falls back to plain text path (user style settings apply).
    var styledASSSubtitles: Bool {
        didSet { store.set(styledASSSubtitles, forKey: Keys.styledASSSubtitles) }
    }

    var subtitleFontSize: SubtitleFontSize {
        didSet { store.set(subtitleFontSize.rawValue, forKey: Keys.subtitleFontSize) }
    }

    var subtitleColor: SubtitleColor {
        didSet { store.set(subtitleColor.rawValue, forKey: Keys.subtitleColor) }
    }

    var subtitleBackground: SubtitleBackground {
        // Write the versioned key; legacy key left intact for downgrade.
        didSet { store.set(subtitleBackground.rawValue, forKey: Keys.subtitleBackgroundV2) }
    }

    /// Applied in SubtitleOverlayView as effectiveTime = currentTime - delay (covers engine + legacy SRTParser paths).
    var subtitleDelaySeconds: Double {
        didSet { store.set(subtitleDelaySeconds, forKey: Keys.subtitleDelaySeconds) }
    }

    var subtitleVerticalPosition: SubtitleVerticalPosition {
        didSet { store.set(subtitleVerticalPosition.rawValue, forKey: Keys.subtitleVerticalPosition) }
    }

    var subtitleFont: SubtitleFont {
        didSet { store.set(subtitleFont.rawValue, forKey: Keys.subtitleFont) }
    }

    var subtitleWeight: SubtitleWeight {
        didSet { store.set(subtitleWeight.rawValue, forKey: Keys.subtitleWeight) }
    }

    /// Default for new sessions; in-player picture button overrides transiently on PlayerViewModel, not here.
    var pictureMode: PictureMode {
        didSet { store.set(pictureMode.rawValue, forKey: Keys.pictureMode) }
    }

    /// Stats panel "i" button; unlike showDiagnosticOverlay NOT gated by LogTap.isDiagnosticBuild (read-only, App Store safe).
    var showStatsForNerds: Bool {
        didSet { store.set(showStatsForNerds, forKey: Keys.showStatsForNerds) }
    }

    var showEngineDiagnostics: Bool {
        didSet { store.set(showEngineDiagnostics, forKey: Keys.showEngineDiagnostics) }
    }

    /// In-player engine log overlay; gated by LogTap.isDiagnosticBuild so it only takes effect in DEBUG/TestFlight.
    var showDiagnosticOverlay: Bool {
        didSet { store.set(showDiagnosticOverlay, forKey: Keys.showDiagnosticOverlay) }
    }

    /// ON filters overlay to DV/HDR/routing chain; OFF renders every ring-buffer line including cache/muxer chatter.
    var focusDiagnosticOverlayOnDV: Bool {
        didSet { store.set(focusDiagnosticOverlayOnDV, forKey: Keys.focusDiagnosticOverlayOnDV) }
    }

    /// ON = lossless FLAC for non-stream-copyable (TrueHD/DTS/DTS-HD MA/MP3/Opus), but AVPlayer decodes to LPCM, downmixed to stereo on stereo-only HDMI sinks. OFF (default) = lossy EAC3 5.1 384 kbps, works on all soundbars but caps 7.1->5.1. Recommend ON only with multichannel-LPCM AVR.
    var preferLosslessAudioBridge: Bool {
        didSet { store.set(preferLosslessAudioBridge, forKey: Keys.preferLosslessAudioBridge) }
    }

    var showScrubPreview: Bool {
        didSet { store.set(showScrubPreview, forKey: Keys.showScrubPreview) }
    }

    /// ON = scrub preview pulls Jellyfin server trickplay tiles when the item has them (decode-free),
    /// else the on-device FrameExtractor. Default OFF (the FrameExtractor is the default source).
    var preferServerTrickplay: Bool {
        didSet { store.set(preferServerTrickplay, forKey: Keys.preferServerTrickplay) }
    }

    /// iPhone player orientation (the in-player lock icon's remembered state): true pins the session
    /// (landscape at launch, current orientation when re-locked mid-play), false follows device rotation.
    /// iPad ignores it (never locked).
    var playerRotationLocked: Bool {
        didSet { store.set(playerRotationLocked, forKey: Keys.playerRotationLocked) }
    }

    var audioBridgeMode: AudioBridgeMode {
        preferLosslessAudioBridge ? .lossless : .surroundCompat
    }

    // MARK: - Init

    private let store: UserDefaults

    /// Prefer v2 versioned key, else migrate legacy: legacy "none" -> .shadow (it drew a drop shadow); fallback .box.
    private static func loadSubtitleBackground(from store: UserDefaults) -> SubtitleBackground {
        if let v2 = store.string(forKey: Keys.subtitleBackgroundV2),
           let parsed = SubtitleBackground(rawValue: v2) {
            return parsed
        }
        guard let legacy = store.string(forKey: Keys.subtitleBackground) else {
            return .box
        }
        switch legacy {
        case "none":    return .shadow
        case "box":     return .box
        case "outline": return .outline
        default:        return .box
        }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        self.autoplayNextEpisode = store.object(forKey: Keys.autoplayNextEpisode) as? Bool ?? true
        self.autoSkipIntro = store.object(forKey: Keys.autoSkipIntro) as? Bool ?? false
        self.autoSkipOutro = store.object(forKey: Keys.autoSkipOutro) as? Bool ?? false
        self.nextEpisodeCountdownSeconds = store.object(forKey: Keys.nextEpisodeCountdownSeconds) as? Int ?? 10
        self.skipIntervalSeconds = store.object(forKey: Keys.skipIntervalSeconds) as? Int ?? 10
        self.preferredAudioLanguage = store.string(forKey: Keys.preferredAudioLanguage)
        self.preferredSubtitleLanguage = store.string(forKey: Keys.preferredSubtitleLanguage)
        self.autoSubtitleForForeignAudio = store.object(forKey: Keys.autoSubtitleForForeignAudio) as? Bool ?? true
        self.styledASSSubtitles = store.object(forKey: Keys.styledASSSubtitles) as? Bool ?? true
        self.subtitleFontSize = (store.string(forKey: Keys.subtitleFontSize))
            .flatMap(SubtitleFontSize.init(rawValue:)) ?? .medium
        self.subtitleColor = (store.string(forKey: Keys.subtitleColor))
            .flatMap(SubtitleColor.init(rawValue:)) ?? .white
        self.subtitleBackground = Self.loadSubtitleBackground(from: store)
        self.subtitleDelaySeconds = store.object(forKey: Keys.subtitleDelaySeconds) as? Double ?? 0
        self.subtitleVerticalPosition = (store.string(forKey: Keys.subtitleVerticalPosition))
            .flatMap(SubtitleVerticalPosition.init(rawValue:)) ?? .default
        self.subtitleFont = (store.string(forKey: Keys.subtitleFont))
            .flatMap(SubtitleFont.init(rawValue:)) ?? .system
        self.subtitleWeight = (store.string(forKey: Keys.subtitleWeight))
            .flatMap(SubtitleWeight.init(rawValue:)) ?? .regular
        self.pictureMode = (store.string(forKey: Keys.pictureMode))
            .flatMap(PictureMode.init(rawValue:)) ?? .original
        self.showStatsForNerds = store.object(forKey: Keys.showStatsForNerds) as? Bool ?? false
        self.showEngineDiagnostics = store.object(forKey: Keys.showEngineDiagnostics) as? Bool ?? false
        self.showDiagnosticOverlay = store.object(forKey: Keys.showDiagnosticOverlay) as? Bool ?? false
        self.focusDiagnosticOverlayOnDV = store.object(forKey: Keys.focusDiagnosticOverlayOnDV) as? Bool ?? true
        self.preferLosslessAudioBridge = store.object(forKey: Keys.preferLosslessAudioBridge) as? Bool ?? false
        self.showScrubPreview = store.object(forKey: Keys.showScrubPreview) as? Bool ?? true
        self.preferServerTrickplay = store.object(forKey: Keys.preferServerTrickplay) as? Bool ?? false
        self.playerRotationLocked = store.object(forKey: Keys.playerRotationLocked) as? Bool ?? true
    }
}
