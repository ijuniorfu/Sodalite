import Foundation
import Observation
import SwiftUI

/// Cosmetic choices unlocked by the Supporter Pack. Non-supporters are
/// pinned to `.system` defaults at read time, the stored value stays
/// intact so we don't wipe a selection after a refund-then-repurchase
/// cycle.
///
/// Backed by `UserDefaults`, not the Keychain, none of this is sensitive
/// and losing the preference on wipe is fine.
@Observable
@MainActor
final class AppearancePreferences {

    // MARK: - Accent

    enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
        case system   // Default, free for everyone
        // Warm family
        case gold
        case sunset
        case rose
        case crimson
        // Cool family
        case ocean
        case mint
        case emerald
        // Purple family
        case amethyst
        case lavender

        var id: String { rawValue }

        /// Localized display name. Resolved inside the enum so both
        /// arguments to `String(localized:defaultValue:)` stay as
        /// compile-time string literals, the initializer can't accept
        /// runtime `String.LocalizationValue` values.
        var title: String {
            switch self {
            case .system:
                String(localized: "appearance.accent.system",   defaultValue: "System Blue")
            case .gold:
                String(localized: "appearance.accent.gold",     defaultValue: "Gold")
            case .sunset:
                String(localized: "appearance.accent.sunset",   defaultValue: "Sunset")
            case .rose:
                String(localized: "appearance.accent.rose",     defaultValue: "Rose")
            case .crimson:
                String(localized: "appearance.accent.crimson",  defaultValue: "Crimson")
            case .ocean:
                String(localized: "appearance.accent.ocean",    defaultValue: "Ocean")
            case .mint:
                String(localized: "appearance.accent.mint",     defaultValue: "Mint")
            case .emerald:
                String(localized: "appearance.accent.emerald",  defaultValue: "Emerald")
            case .amethyst:
                String(localized: "appearance.accent.amethyst", defaultValue: "Amethyst")
            case .lavender:
                String(localized: "appearance.accent.lavender", defaultValue: "Lavender")
            }
        }

        /// Hex chosen to work against the dark Liquid-Glass backdrop,
        /// punchy but not neon, all sitting around L≈0.65–0.75 so text
        /// drawn on top in `.tint` stays legible. Swatches render
        /// straight from these.
        ///
        /// `.system` hard-codes the asset-catalog accent RGB rather
        /// than `Color.accentColor`, because the semantic value
        /// follows the current `.tint(...)` in the environment,
        /// otherwise the swatch would shift with whatever custom
        /// color is active and stop reading as "System Blue".
        var color: Color {
            switch self {
            case .system:   Color(red: 0.00, green: 0.478, blue: 1.00)
            case .gold:     Color(red: 0.98, green: 0.79, blue: 0.35)
            case .sunset:   Color(red: 1.00, green: 0.60, blue: 0.30)
            case .rose:     Color(red: 0.99, green: 0.57, blue: 0.70)
            case .crimson:  Color(red: 0.94, green: 0.35, blue: 0.40)
            case .ocean:    Color(red: 0.30, green: 0.78, blue: 0.88)
            case .mint:     Color(red: 0.40, green: 0.87, blue: 0.70)
            case .emerald:  Color(red: 0.30, green: 0.80, blue: 0.50)
            case .amethyst: Color(red: 0.69, green: 0.50, blue: 0.95)
            case .lavender: Color(red: 0.78, green: 0.68, blue: 0.98)
            }
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let accentChoice = "appearance.accentChoice"
        static let showContentLogos = "appearance.showContentLogos"
        static let continueWatchingUsesSeriesArt = "appearance.continueWatchingUsesSeriesArt"
        static let largeCards = "appearance.largeCards"
        static let nowPlayingUsesSeriesPoster = "appearance.nowPlayingUsesSeriesPoster"
    }

    /// Multiplier applied to media-card dimensions when `largeCards` is on.
    /// 1.3 gives a noticeably bigger Apple TV-style card without dropping
    /// so many cards per row that the rows feel empty.
    static let largeCardScale: CGFloat = 1.3

    // MARK: - State

    var accentChoice: AccentChoice {
        didSet { store.set(accentChoice.rawValue, forKey: Keys.accentChoice) }
    }

    /// Show the title-card logo image (when the item has one) in place of
    /// the plain text title on the Movie / Series / Episode detail
    /// screens. Free for everyone, unlike the accent picker; the detail
    /// views fall back to the text title when the item has no logo or
    /// this is off. Default on.
    var showContentLogos: Bool {
        didSet { store.set(showContentLogos, forKey: Keys.showContentLogos) }
    }

    /// Continue Watching / Up Next cards show the series' landscape Thumb
    /// art instead of the episode's video-frame still. Default off (keeps
    /// the where-you-left-off frame). Falls back Thumb -> Backdrop ->
    /// still when a show has no Thumb.
    var continueWatchingUsesSeriesArt: Bool {
        didSet { store.set(continueWatchingUsesSeriesArt, forKey: Keys.continueWatchingUsesSeriesArt) }
    }

    /// Render the Home media cards larger (Apple TV-style). Default off.
    var largeCards: Bool {
        didSet { store.set(largeCards, forKey: Keys.largeCards) }
    }

    /// System Now-Playing artwork uses the series poster (Primary) rather
    /// than the episode still, which fills the square Control Center slot
    /// better. Default off. Movies are unaffected (no series).
    var nowPlayingUsesSeriesPoster: Bool {
        didSet { store.set(nowPlayingUsesSeriesPoster, forKey: Keys.nowPlayingUsesSeriesPoster) }
    }

    /// Scale factor for media-card dimensions, driven by `largeCards`.
    var cardScale: CGFloat {
        largeCards ? Self.largeCardScale : 1.0
    }

    // MARK: - Init

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        let raw = store.string(forKey: Keys.accentChoice) ?? AccentChoice.system.rawValue
        self.accentChoice = AccentChoice(rawValue: raw) ?? .system
        self.showContentLogos = store.object(forKey: Keys.showContentLogos) as? Bool ?? true
        self.continueWatchingUsesSeriesArt = store.object(forKey: Keys.continueWatchingUsesSeriesArt) as? Bool ?? false
        self.largeCards = store.object(forKey: Keys.largeCards) as? Bool ?? false
        self.nowPlayingUsesSeriesPoster = store.object(forKey: Keys.nowPlayingUsesSeriesPoster) as? Bool ?? false
    }

    /// Effective tint to apply to the UI. Non-supporters always get
    /// `.system` regardless of a previously stored choice, so downgrade
    /// paths are graceful.
    func effectiveAccent(isSupporter: Bool) -> AccentChoice {
        isSupporter ? accentChoice : .system
    }

    /// The Color to pass into SwiftUI's `.tint(_:)`. Returns `nil` for
    /// the `.system` case so we don't override SwiftUI's default tint
    /// with a self-referential `Color.accentColor`, which, if the
    /// `AccentColor.colorset` ever ends up empty or stale, resolves to
    /// white and makes every tinted button unreadable.
    func effectiveTint(isSupporter: Bool) -> Color? {
        let choice = effectiveAccent(isSupporter: isSupporter)
        return choice == .system ? nil : choice.color
    }
}
