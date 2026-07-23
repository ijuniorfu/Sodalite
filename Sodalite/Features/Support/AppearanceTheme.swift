import SwiftUI

enum AppearanceTier: Sendable {
    case free
    case supporter
}

enum AccentCategory: String, CaseIterable, Identifiable, Sendable {
    case basic
    case pastel
    case bold
    case electric
    case cinematic

    var id: String { rawValue }
    var presets: [AccentPreset] {
        AccentPreset.allCases.filter { $0.category == self }
    }
}

struct RGBColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xff) / 255
        green = Double((hex >> 8) & 0xff) / 255
        blue = Double(hex & 0xff) / 255
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    func contrastRatio(with other: RGBColor) -> Double {
        let high = max(relativeLuminance, other.relativeLuminance)
        let low = min(relativeLuminance, other.relativeLuminance)
        return (high + 0.05) / (low + 0.05)
    }

    private var relativeLuminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red)
            + 0.7152 * linear(green)
            + 0.0722 * linear(blue)
    }
}

struct AccentPalette: Equatable, Sendable {
    let control: RGBColor
    let navigation: RGBColor
    let focus: RGBColor
}

enum AccentPreset: String, CaseIterable, Identifiable, Sendable {
    case systemBlue = "system"
    case orange
    case violet
    case sky = "ocean"
    case mint
    case blush = "rose"
    case apricot = "sunset"
    case lavender
    case cobalt
    case emerald
    case ruby = "crimson"
    case amber
    case royalViolet = "amethyst"
    case cyan
    case magenta
    case lime
    case ultraviolet
    case solarOrange
    case petrol
    case burgundy
    case indigo
    case copper
    case champagne = "gold"

    static let system: AccentPreset = .systemBlue
    static let gold: AccentPreset = .champagne
    static let sunset: AccentPreset = .apricot
    static let rose: AccentPreset = .blush
    static let crimson: AccentPreset = .ruby
    static let ocean: AccentPreset = .sky
    static let amethyst: AccentPreset = .royalViolet

    var id: String { rawValue }

    var category: AccentCategory {
        switch self {
        case .systemBlue, .orange, .violet: .basic
        case .sky, .mint, .blush, .apricot, .lavender: .pastel
        case .cobalt, .emerald, .ruby, .amber, .royalViolet: .bold
        case .cyan, .magenta, .lime, .ultraviolet, .solarOrange: .electric
        case .petrol, .burgundy, .indigo, .copper, .champagne: .cinematic
        }
    }

    var tier: AppearanceTier {
        category == .basic ? .free : .supporter
    }

    var palette: AccentPalette {
        switch self {
        case .systemBlue: .init(control: .init(hex: 0x007AFF), navigation: .init(hex: 0x006ADE), focus: .init(hex: 0x007AFF))
        case .orange: .init(control: .init(hex: 0xFF9500), navigation: .init(hex: 0xA15E00), focus: .init(hex: 0xFF9500))
        case .violet: .init(control: .init(hex: 0xAF52DE), navigation: .init(hex: 0x9C49C6), focus: .init(hex: 0xAF52DE))
        case .sky: .init(control: .init(hex: 0x72C7ED), navigation: .init(hex: 0x43758C), focus: .init(hex: 0x72C7ED))
        case .mint: .init(control: .init(hex: 0x78D9B8), navigation: .init(hex: 0x427765), focus: .init(hex: 0x78D9B8))
        case .blush: .init(control: .init(hex: 0xEE91AD), navigation: .init(hex: 0x985D6F), focus: .init(hex: 0xEE91AD))
        case .apricot: .init(control: .init(hex: 0xF2AA72), navigation: .init(hex: 0x8F6443), focus: .init(hex: 0xF2AA72))
        case .lavender: .init(control: .init(hex: 0xB7A0EA), navigation: .init(hex: 0x756696), focus: .init(hex: 0xB7A0EA))
        case .cobalt: .init(control: .init(hex: 0x2247B8), navigation: .init(hex: 0x2247B8), focus: .init(hex: 0x3F5FC1))
        case .emerald: .init(control: .init(hex: 0x00A86B), navigation: .init(hex: 0x007E50), focus: .init(hex: 0x00A86B))
        case .ruby: .init(control: .init(hex: 0xD7264F), navigation: .init(hex: 0xD3254D), focus: .init(hex: 0xD7264F))
        case .amber: .init(control: .init(hex: 0xD88700), navigation: .init(hex: 0x9C6100), focus: .init(hex: 0xD88700))
        case .royalViolet: .init(control: .init(hex: 0x5E2ABF), navigation: .init(hex: 0x5E2ABF), focus: .init(hex: 0x764AC9))
        case .cyan: .init(control: .init(hex: 0x00D7FF), navigation: .init(hex: 0x00788F), focus: .init(hex: 0x00D7FF))
        case .magenta: .init(control: .init(hex: 0xFF2DAA), navigation: .init(hex: 0xCC2488), focus: .init(hex: 0xFF2DAA))
        case .lime: .init(control: .init(hex: 0xA6F000), navigation: .init(hex: 0x537800), focus: .init(hex: 0xA6F000))
        case .ultraviolet: .init(control: .init(hex: 0x8F00FF), navigation: .init(hex: 0x8F00FF), focus: .init(hex: 0x8F00FF))
        case .solarOrange: .init(control: .init(hex: 0xFF5A1F), navigation: .init(hex: 0xC24418), focus: .init(hex: 0xFF5A1F))
        case .petrol: .init(control: .init(hex: 0x0F8B8D), navigation: .init(hex: 0x0D7A7C), focus: .init(hex: 0x0F8B8D))
        case .burgundy: .init(control: .init(hex: 0x9B234A), navigation: .init(hex: 0x9B234A), focus: .init(hex: 0xA84062))
        case .indigo: .init(control: .init(hex: 0x343A8F), navigation: .init(hex: 0x343A8F), focus: .init(hex: 0x5B5FA4))
        case .copper: .init(control: .init(hex: 0xB96A3B), navigation: .init(hex: 0xA35D34), focus: .init(hex: 0xB96A3B))
        case .champagne: .init(control: .init(hex: 0xC49A55), navigation: .init(hex: 0x876A3B), focus: .init(hex: 0xC49A55))
        }
    }

    var color: Color { palette.control.color }
    var title: String { rawValue }
}

enum BackgroundStyle: String, CaseIterable, Identifiable, Sendable {
    case graphiteGlass
    case oledBlack
    case accentAurora
    case polishedCrystal
    case cinemaNoir

    var id: String { rawValue }
    var tier: AppearanceTier {
        switch self {
        case .graphiteGlass, .oledBlack: .free
        case .accentAurora, .polishedCrystal, .cinemaNoir: .supporter
        }
    }
}

struct ResolvedAppearanceTheme: Equatable, Sendable {
    let accent: AccentPreset
    let background: BackgroundStyle
    var palette: AccentPalette { accent.palette }

    static let `default` = ResolvedAppearanceTheme(
        accent: .systemBlue,
        background: .graphiteGlass
    )
}

enum AppearanceThemeResolver {
    static func resolve(
        storedAccent: AccentPreset,
        storedBackground: BackgroundStyle,
        isSupporter: Bool
    ) -> ResolvedAppearanceTheme {
        let accent = isSupporter || storedAccent.tier == .free
            ? storedAccent
            : .systemBlue
        let background = isSupporter || storedBackground.tier == .free
            ? storedBackground
            : .graphiteGlass
        return ResolvedAppearanceTheme(accent: accent, background: background)
    }
}
