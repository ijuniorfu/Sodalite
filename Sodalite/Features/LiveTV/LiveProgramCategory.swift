import SwiftUI

/// The category rows of the Live TV "Übersicht" tab, mirroring Jellyfin's
/// native "Programme" view. Each case maps to a single boolean filter on
/// `/LiveTv/Programs/Recommended` (see `JellyfinEndpoint`). Order here is the
/// on-screen row order.
enum LiveProgramCategory: String, CaseIterable, Identifiable {
    case airing
    case series
    case movies
    case sports
    case kids
    case news

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .airing: "livetv.category.airing"
        case .series: "livetv.category.series"
        case .movies: "livetv.category.movies"
        case .sports: "livetv.category.sports"
        case .kids:   "livetv.category.kids"
        case .news:   "livetv.category.news"
        }
    }
}
