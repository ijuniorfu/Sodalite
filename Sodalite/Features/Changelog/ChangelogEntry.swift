import Foundation

/// One release worth of user-visible changes; newest-first in `Changelog.entries`.
struct ChangelogEntry: Identifiable, Sendable {
    let version: String
    let highlights: [ChangelogHighlight]

    var id: String { version }
}

/// One bullet point in a changelog entry; kind (new / improve / fix) selects colour + icon.
struct ChangelogHighlight: Identifiable, Sendable {
    let id = UUID()
    let kind: Kind
    let title: LocalizedStringResource
    let description: LocalizedStringResource?
    /// Override the kind's default SF Symbol.
    let symbolOverride: String?

    var systemImage: String {
        symbolOverride ?? kind.defaultSymbol
    }

    enum Kind: String, Sendable {
        case new
        case improve
        case fix

        var defaultSymbol: String {
            switch self {
            case .new: "sparkles"
            case .improve: "arrow.up.circle.fill"
            case .fix: "wrench.fill"
            }
        }
    }
}

extension ChangelogHighlight {
    init(
        _ kind: Kind,
        _ title: LocalizedStringResource,
        _ description: LocalizedStringResource? = nil,
        icon: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.description = description
        self.symbolOverride = icon
    }
}
