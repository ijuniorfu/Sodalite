import Foundation
import CoreGraphics
import Observation
import AetherEngine

/// Device-local playback preferences. Backed by `UserDefaults` so they
/// survive app restarts; intentionally device-local because these are
/// user-interaction tuning, not content choices.
///
/// Read/write from anywhere through `DependencyContainer.playbackPreferences`.
/// The class is `@Observable`, so SwiftUI views update automatically when a
/// setting changes.
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
        static let subtitleFontSize = "playback.subtitleFontSize"
        static let subtitleColor = "playback.subtitleColor"
        static let subtitleBackground = "playback.subtitleBackground"
        /// Versioned key for `subtitleBackground` so the case split that
        /// promoted the old "none" (which actually drew a shadow) to its
        /// own `.shadow` case can land without silently flipping shadowed
        /// users into truly-plain text. Read v2 first; if absent, migrate
        /// the legacy v1 value (legacy "none" -> new .shadow).
        static let subtitleBackgroundV2 = "playback.subtitleBackgroundV2"
        static let subtitleDelaySeconds = "playback.subtitleDelaySeconds"
        /// Legacy ±200 pt slider. v2 supersedes it with a semantic enum;
        /// existing values are not migrated (clean reset on first launch
        /// of the new build, see SubtitleVerticalPosition for why).
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
    }

    // MARK: - Allowed Values

    /// 0 = disabled (countdown doesn't appear), otherwise countdown seconds.
    static let countdownChoices: [Int] = [0, 5, 10, 15]
    static let skipIntervalChoices: [Int] = [5, 10, 15, 30]

    /// Subtitle-delay choices in seconds. Negative shifts subs *earlier*
    /// (they appear before the audio line they're translating); positive
    /// shifts them *later*. Step density is finer near zero where most
    /// real-world out-of-sync issues land, wider steps further out for
    /// the rare badly-muxed track.
    static let subtitleDelayChoices: [Double] = [
        -5, -3, -2, -1.5, -1, -0.5, -0.25, 0, 0.25, 0.5, 1, 1.5, 2, 3, 5
    ]

    // Legacy `subtitleVerticalOffsetChoices` (±200 pt slider) replaced
    // by `SubtitleVerticalPosition`. Kept the storage key in `Keys`
    // for posterity, but no migration: the pt-to-fraction math is
    // ambiguous on the asymmetric new scale, and TestFlight users
    // re-picking the setting once is cheaper than carrying broken
    // migrated state.

    /// Shared language options, alphabetical by display name. ISO 639-2/B
    /// bibliographic codes (Jellyfin's convention: "deu" not "ger", "cze"
    /// not "ces", etc.).
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

    /// Audio pref dropdown, "Auto" first, then the shared alphabetical list.
    static var audioLanguageChoices: [LanguageChoice] {
        [LanguageChoice(code: nil, short: "Auto", titleKey: "settings.playback.language.auto")]
            + baseLanguages
    }

    /// Subtitle pref dropdown, same shape as audio: "Auto" first,
    /// then the alphabetical list. `nil` code lets the per-track
    /// auto-pick logic (foreign-audio detection, system language)
    /// decide; an explicit language code pins the preference.
    static var subtitleLanguageChoices: [LanguageChoice] {
        [LanguageChoice(code: nil, short: "Auto", titleKey: "settings.playback.language.auto")]
            + baseLanguages
    }

    struct LanguageChoice: Hashable, Sendable {
        /// ISO 639-2/B code as Jellyfin uses it (e.g. "deu", "eng"),
        /// or nil for "use the stream's default / current logic".
        let code: String?
        /// Short label for the chip UI ("DE", "EN", "Auto").
        let short: String
        /// Localization key for the long name ("Deutsch", "Englisch", …).
        let titleKey: String
    }

    /// Subtitle text size relative to the default. Used for both
    /// the engine's text-cue overlay and the legacy SRTParser path.
    /// Calibrated for tvOS viewing distance (3–5 m from a 55–65″ TV)
    ///, sizes land between ~32 pt (small) and ~68 pt (xlarge),
    /// roughly aligned with Apple TV's own subtitle-size
    /// accessibility range from Default to Extra Extra Large.
    enum SubtitleFontSize: String, CaseIterable, Sendable, Identifiable {
        case small, medium, large, xlarge
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.size.\(rawValue)" }
        /// Multiplier applied to the 28 pt base. The multipliers grow
        /// roughly geometrically (1.15 → 1.45 → 1.85 → 2.4) so each
        /// step up looks distinctly bigger from across the room.
        var scale: CGFloat {
            switch self {
            case .small: return 1.15
            case .medium: return 1.45
            case .large: return 1.85
            case .xlarge: return 2.4
            }
        }
    }

    /// Foreground colour for subtitle text. Three options that cover
    /// the tracks people actually mix and match (white = default,
    /// yellow = accessibility / Disney-style, grey = soften
    /// against bright HDR scenes).
    enum SubtitleColor: String, CaseIterable, Sendable, Identifiable {
        case white, yellow, gray
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.color.\(rawValue)" }
    }

    /// How the subtitle text reads against the video frame.
    ///
    /// - `box`: classic semi-transparent black backing.
    /// - `outline`: thin black stroke around the glyphs, no fill, best
    ///   when the video has heavy contrast already.
    /// - `shadow`: soft drop shadow behind plain text. Used to be the
    ///   behaviour of `.none` (which was a misnomer, the shadow was
    ///   always there) and is preserved here so existing users see no
    ///   visual change after the case split.
    /// - `none`: truly naked text, no decoration. New case for users
    ///   who explicitly don't want anything modifying the glyphs.
    enum SubtitleBackground: String, CaseIterable, Sendable, Identifiable {
        case box, outline, shadow, none
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.background.\(rawValue)" }
    }

    /// Vertical placement of the rendered subtitle, as an ordinal step
    /// on a low-to-high scale. `default` is the no-override case (text
    /// uses the historical baseline of ~80 pt above the player rect's
    /// bottom edge, bitmap cues stay at their source-baked position).
    /// `bottom`, `step1`, `step2`, `step3` anchor the baseline to a
    /// fraction of the player rect height measured from the bottom
    /// edge, so the position scales identically on 1080p and 2160p
    /// panels.
    ///
    /// Localized labels (en): Default / Bottom Edge / Low / Mid-Low /
    /// Mid. The raw case names stay stable for persisted UserDefaults
    /// values; only the display strings in Localizable.xcstrings carry
    /// the descriptive naming.
    ///
    /// Scale shape: no negative half (no real-world use case surfaced
    /// for lifting subs into the picture's upper half), explicit
    /// `default` instead of a "0" entry so users can opt out of the
    /// override entirely. The opt-out matters for PGS / DVB / DVD
    /// where the source carries layout-sensitive positions like sign
    /// translations at frame-top.
    enum SubtitleVerticalPosition: String, CaseIterable, Sendable, Identifiable {
        case `default`
        case bottom
        case step1
        case step2
        case step3

        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.position.\(rawValue)" }

        /// Fraction of the player rect height (measured from the
        /// bottom edge) where the subtitle baseline should sit, or
        /// `nil` for "no override". `nil` falls back to the historical
        /// text baseline and leaves bitmap cues alone.
        var fractionFromBottom: Double? {
            switch self {
            case .default: return nil
            case .bottom:  return 0.01
            case .step1:   return 0.10
            case .step2:   return 0.20
            case .step3:   return 0.30
            }
        }
    }

    /// Subtitle text font. `system` uses tvOS's SF Pro; `highLegibility`
    /// uses the bundled Atkinson Hyperlegible (Braille Institute,
    /// designed for low-vision readers but legible for everyone). The
    /// custom font only affects text cues; PGS / DVB / DVD bitmap cues
    /// come pre-rendered from the source and ignore this setting.
    enum SubtitleFont: String, CaseIterable, Sendable, Identifiable {
        case system, highLegibility
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.font.\(rawValue)" }
    }

    /// Subtitle text weight. `regular` is the default and matches
    /// surrounding tvOS UI weight, `bold` is the legacy semibold-ish
    /// rendering that some users prefer for higher contrast against
    /// busy backgrounds. Applied to both the system and the
    /// high-legibility font (SF Pro regular / semibold, or Atkinson
    /// Hyperlegible Regular / Bold). Only affects text cues, bitmap
    /// cues are pre-rendered and ignore weight just like font choice.
    enum SubtitleWeight: String, CaseIterable, Sendable, Identifiable {
        case regular, bold
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.weight.\(rawValue)" }
    }

    /// How the rendered video frame fills the available player area.
    /// `original` preserves the source aspect ratio with letterbox /
    /// pillarbox bars where needed (the safe default, never hides
    /// content). `fill` zooms in and crops the overflow so the frame
    /// covers the screen edge to edge, useful for 4:3 episodes on
    /// a 16:9 TV or 2.39:1 cinemascope content where the user prefers
    /// no letterbox bars. Maps directly to AVLayerVideoGravity in the
    /// engine.
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

    /// Auto-enable subtitles when the playing audio track isn't in the
    /// user's preferred audio language. Default ON because that mirrors
    /// the streaming-app convention (Netflix et al.), if the user wants
    /// German and the episode only has English, they almost always want
    /// German subs on top. Flip off for users who don't want subs ever.
    var autoSubtitleForForeignAudio: Bool {
        didSet { store.set(autoSubtitleForForeignAudio, forKey: Keys.autoSubtitleForForeignAudio) }
    }

    var subtitleFontSize: SubtitleFontSize {
        didSet { store.set(subtitleFontSize.rawValue, forKey: Keys.subtitleFontSize) }
    }

    var subtitleColor: SubtitleColor {
        didSet { store.set(subtitleColor.rawValue, forKey: Keys.subtitleColor) }
    }

    var subtitleBackground: SubtitleBackground {
        // Write the versioned key on every set. The legacy key is left
        // alone, both to keep this writer minimal and to let users who
        // downgrade to an older build still see something sensible.
        didSet { store.set(subtitleBackground.rawValue, forKey: Keys.subtitleBackgroundV2) }
    }

    /// Offset applied to subtitle cue timing when rendering. Positive
    /// values delay the subtitle (it appears *after* the corresponding
    /// audio); negative values pull it forward. Applied in
    /// `SubtitleOverlayView` as `effectiveTime = currentTime - delay`,
    /// so a single value covers both the engine streaming path and
    /// the legacy HTTP/SRTParser fallback.
    var subtitleDelaySeconds: Double {
        didSet { store.set(subtitleDelaySeconds, forKey: Keys.subtitleDelaySeconds) }
    }

    /// Vertical placement of the rendered subtitle on screen. Five
    /// downward-only steps plus an explicit `default` (no override).
    /// Persisted as the enum's raw string value. See
    /// `SubtitleVerticalPosition` for the scale rationale.
    var subtitleVerticalPosition: SubtitleVerticalPosition {
        didSet { store.set(subtitleVerticalPosition.rawValue, forKey: Keys.subtitleVerticalPosition) }
    }

    /// Subtitle text font for text-cue rendering. Bitmap cues
    /// (PGS / DVB / DVD) are unaffected because the source ships
    /// pre-rendered pixels.
    var subtitleFont: SubtitleFont {
        didSet { store.set(subtitleFont.rawValue, forKey: Keys.subtitleFont) }
    }

    /// Subtitle text weight. Defaults to `.regular` so subtitles read
    /// at tvOS UI weight; `.bold` brings back the older heavier
    /// rendering for users who want more contrast against busy
    /// backgrounds.
    var subtitleWeight: SubtitleWeight {
        didSet { store.set(subtitleWeight.rawValue, forKey: Keys.subtitleWeight) }
    }

    /// Default picture-fill mode for new playback sessions. The
    /// in-player picture button can override this for the current
    /// session without persisting, that's a transient state on
    /// PlayerViewModel, not on the prefs.
    var pictureMode: PictureMode {
        didSet { store.set(pictureMode.rawValue, forKey: Keys.pictureMode) }
    }

    /// Mount an "i" button in the player transport bar that opens a
    /// stats panel (codec, decoder, container, bitrate, …). Default off
    /// because it's surface noise for casual users; enthusiasts who
    /// want to keep tabs on what their files are doing flip it on.
    /// Unlike `showDiagnosticOverlay` this is not gated by
    /// `LogTap.isDiagnosticBuild`, the overlay is read-only and safe
    /// to ship to the App Store.
    var showStatsForNerds: Bool {
        didSet { store.set(showStatsForNerds, forKey: Keys.showStatsForNerds) }
    }

    var showEngineDiagnostics: Bool {
        didSet { store.set(showEngineDiagnostics, forKey: Keys.showEngineDiagnostics) }
    }

    /// Show the in-player engine log overlay (top-left). Default off
    /// so the overlay doesn't ride along on every TestFlight build; the
    /// `LogTap.isDiagnosticBuild` gate still hides the toggle entirely
    /// in App Store builds, so this only takes effect in DEBUG and
    /// TestFlight where the overlay is even mountable.
    var showDiagnosticOverlay: Bool {
        didSet { store.set(showDiagnosticOverlay, forKey: Keys.showDiagnosticOverlay) }
    }

    /// When ON, the diagnostic log overlay filters down to the DV / HDR
    /// / routing chain (engine dispatch, HLS routing state, item track
    /// dumps, panel criteria, audio route). When OFF, every line from
    /// the ring buffer is rendered, including per-segment cache /
    /// muxer chatter. Default ON because the focus surface is what's
    /// usually being photographed for support reports.
    var focusDiagnosticOverlayOnDV: Bool {
        didSet { store.set(focusDiagnosticOverlayOnDV, forKey: Keys.focusDiagnosticOverlayOnDV) }
    }

    /// When ON, the audio bridge uses lossless FLAC encoding for
    /// sources that can't stream-copy into fMP4 (TrueHD, DTS, DTS-HD MA,
    /// MP3, Opus). Lossless quality, up to 7.1 channels.
    ///
    /// Caveat: AVPlayer decodes FLAC to LPCM and routes via the active
    /// HDMI port's LPCM channel capacity. On devices that only accept
    /// stereo LPCM via HDMI (Sonos Arc, most consumer soundbars), the
    /// multichannel LPCM gets downmixed to stereo before output.
    ///
    /// When OFF (default), the bridge uses lossy EAC3 5.1 at 384 kbps.
    /// AVPlayer hands the encoded bitstream to HDMI; the sink decodes
    /// its own 5.1 mix. Works on essentially every modern soundbar
    /// and AVR, including those that don't accept multichannel LPCM,
    /// but caps 7.1 sources to 5.1.
    ///
    /// Recommended ON only if you have an AVR (Denon / Marantz / NAD)
    /// that accepts multichannel LPCM via HDMI; OFF is the safer
    /// default for soundbars and basic AVRs.
    var preferLosslessAudioBridge: Bool {
        didSet { store.set(preferLosslessAudioBridge, forKey: Keys.preferLosslessAudioBridge) }
    }

    /// Show a trickplay thumbnail of the frame while scrubbing. Default
    /// on. Off disables tile-sheet downloads entirely (the transport bar
    /// shows the time only).
    var showScrubPreview: Bool {
        didSet { store.set(showScrubPreview, forKey: Keys.showScrubPreview) }
    }

    /// Map the user-facing toggle to the engine's `AudioBridgeMode`.
    var audioBridgeMode: AudioBridgeMode {
        preferLosslessAudioBridge ? .lossless : .surroundCompat
    }

    // MARK: - Init

    private let store: UserDefaults

    /// Resolve the subtitle-background value, preferring the versioned
    /// key when present and otherwise migrating from the legacy one.
    /// Legacy `"none"` rendered with a soft drop shadow, so map it to
    /// the new `.shadow` case to preserve appearance for existing users.
    /// Anything unrecognised falls back to the default `.box`.
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
    }
}
