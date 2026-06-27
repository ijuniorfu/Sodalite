import SwiftUI

struct SeerrHorizontalMediaRow: View {
    let title: LocalizedStringKey
    let items: [SeerrMedia]
    var isLoadingMore: Bool = false
    var onItemSelected: ((SeerrMedia) -> Void)?
    var onNeedsMore: (() -> Void)?

    // Paginate a few items before the end so new cards land before focus reaches them.
    private let prefetchThreshold = 5

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, metrics.rowInset)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: metrics.itemSpacing) {
                    // stableKey not id: TMDB ids collide across movie/tv (trending mixes both); duplicate ForEach ids cause ghost cards and focus jumps.
                    ForEach(Array(items.enumerated()), id: \.element.stableKey) { index, media in
                        FocusableCard {
                            onItemSelected?(media)
                        } content: { isFocused in
                            SeerrMediaCard(media: media, isFocused: isFocused)
                        }
                        .onAppear {
                            if index >= items.count - prefetchThreshold {
                                onNeedsMore?()
                            }
                        }
                    }

                    if isLoadingMore {
                        ProgressView()
                            .frame(width: metrics.posterSize.width, height: metrics.posterSize.height)
                    }
                }
                .padding(.horizontal, metrics.rowInset)
                .padding(.vertical, metrics.rowVerticalPadding)
            }
        }
    }
}
