import SwiftUI

struct DetailRouterView: View {
    let item: JellyfinItem

    var body: some View {
        Group {
            switch item.type {
            case .movie:
                MovieDetailView(item: item)
            case .series:
                SeriesDetailView(item: item)
            case .episode:
                if let seriesId = item.seriesId {
                    SeriesDetailView(
                        item: JellyfinItem(seriesStub: seriesId, name: item.seriesName ?? ""),
                        initialEpisode: item
                    )
                } else {
                    // No parent series to show: fall back to the
                    // standalone episode page.
                    MovieDetailView(item: item)
                }
            case .boxSet:
                CollectionDetailView(item: item)
            default:
                MovieDetailView(item: item)
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}
