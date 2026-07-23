import Foundation
import Observation
import SwiftUI

/// Supporter-gated cosmetics preserve stored values across refund and repurchase.
@Observable
@MainActor
final class AppearancePreferences {

    typealias AccentChoice = AccentPreset

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
        static let backgroundStyle = "appearance.backgroundStyle"
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

    var backgroundStyle: BackgroundStyle {
        didSet { store.set(backgroundStyle.rawValue, forKey: Keys.backgroundStyle) }
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
        let rawAccent = store.string(forKey: Keys.accentChoice) ?? AccentPreset.systemBlue.rawValue
        self.accentChoice = AccentPreset(rawValue: rawAccent) ?? .systemBlue
        let rawBackground = store.string(forKey: Keys.backgroundStyle)
        self.backgroundStyle = rawBackground.flatMap(BackgroundStyle.init(rawValue:))
            ?? .graphiteGlass
        self.showContentLogos = store.object(forKey: Keys.showContentLogos) as? Bool ?? true
        self.continueWatchingImage = store.string(forKey: Keys.continueWatchingImage)
            .flatMap(ContinueWatchingImage.init(rawValue:)) ?? .still
        self.largeCards = store.object(forKey: Keys.largeCards) as? Bool ?? false
        self.nowPlayingUsesSeriesPoster = store.object(forKey: Keys.nowPlayingUsesSeriesPoster) as? Bool ?? false
    }

    func resolvedTheme(isSupporter: Bool) -> ResolvedAppearanceTheme {
        AppearanceThemeResolver.resolve(
            storedAccent: accentChoice,
            storedBackground: backgroundStyle,
            isSupporter: isSupporter
        )
    }

    func effectiveAccent(isSupporter: Bool) -> AccentChoice {
        resolvedTheme(isSupporter: isSupporter).accent
    }

    func effectiveTint(isSupporter: Bool) -> Color? {
        resolvedTheme(isSupporter: isSupporter).palette.control.color
    }
}
