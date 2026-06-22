import SwiftUI

/// Live TV "Übersicht" category rows (mirrors Jellyfin's "Programme"). Each case is a boolean filter
/// on `/LiveTv/Programs/Recommended`; declaration order is on-screen row order.
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
