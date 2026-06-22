import Foundation
import Observation
import SwiftUI

/// Supporter-gated cosmetics; non-supporters pinned to `.system` at read time but stored value preserved across refund/repurchase. UserDefaults, not Keychain.
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

        /// Literal keys/defaults so `String(localized:defaultValue:)` compile-time-literal requirement holds.
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

        /// Hex tuned for dark Liquid-Glass backdrop, L≈0.65–0.75 so `.tint` text stays legible; `.system` hardcodes asset RGB not `Color.accentColor` (which would follow environment tint).
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

    // MARK: - Continue Watching image

    enum ContinueWatchingImage: String, CaseIterable, Identifiable, Sendable {
        case still     // the episode's own frame
        case backdrop  // the show's landscape backdrop
        case thumb     // the show's landscape Thumb promo art

        var id: String { rawValue }

        /// Literal keys/defaults so `String(localized:defaultValue:)` compile-time-literal requirement holds.
        var title: String {
            switch self {
            case .still:
                String(localized: "settings.appearance.cwImage.still", defaultValue: "Episode image")
            case .backdrop:
                String(localized: "settings.appearance.cwImage.backdrop", defaultValue: "Backdrop")
            case .thumb:
                String(localized: "settings.appearance.cwImage.thumb", defaultValue: "Thumb")
            }
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let accentChoice = "appearance.accentChoice"
        static let showContentLogos = "appearance.showContentLogos"
        static let continueWatchingImage = "appearance.continueWatchingImage"
        static let largeCards = "appearance.largeCards"
        static let nowPlayingUsesSeriesPoster = "appearance.nowPlayingUsesSeriesPoster"
    }

    /// 1.3: noticeably bigger Apple TV-style card without dropping so many cards per row that rows feel empty.
    static let largeCardScale: CGFloat = 1.3

    // MARK: - State

    var accentChoice: AccentChoice {
        didSet { store.set(accentChoice.rawValue, forKey: Keys.accentChoice) }
    }

    /// Logo image instead of text title on detail screens; free for everyone, falls back to text when no logo or off. Default on.
    var showContentLogos: Bool {
        didSet { store.set(showContentLogos, forKey: Keys.showContentLogos) }
    }

    var continueWatchingImage: ContinueWatchingImage {
        didSet { store.set(continueWatchingImage.rawValue, forKey: Keys.continueWatchingImage) }
    }

    var largeCards: Bool {
        didSet { store.set(largeCards, forKey: Keys.largeCards) }
    }

    /// Now-Playing artwork uses series poster (Primary), fills square Control Center slot better. Default off. Movies unaffected (no series).
    var nowPlayingUsesSeriesPoster: Bool {
        didSet { store.set(nowPlayingUsesSeriesPoster, forKey: Keys.nowPlayingUsesSeriesPoster) }
    }

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
        self.continueWatchingImage = store.string(forKey: Keys.continueWatchingImage)
            .flatMap(ContinueWatchingImage.init(rawValue:)) ?? .still
        self.largeCards = store.object(forKey: Keys.largeCards) as? Bool ?? false
        self.nowPlayingUsesSeriesPoster = store.object(forKey: Keys.nowPlayingUsesSeriesPoster) as? Bool ?? false
    }

    /// Non-supporters always get `.system` regardless of stored choice, so downgrade paths are graceful.
    func effectiveAccent(isSupporter: Bool) -> AccentChoice {
        isSupporter ? accentChoice : .system
    }

    /// `nil` for `.system` so we don't self-reference `Color.accentColor`, which resolves to white if `AccentColor.colorset` empty/stale -> unreadable buttons.
    func effectiveTint(isSupporter: Bool) -> Color? {
        let choice = effectiveAccent(isSupporter: isSupporter)
        return choice == .system ? nil : choice.color
    }
}
