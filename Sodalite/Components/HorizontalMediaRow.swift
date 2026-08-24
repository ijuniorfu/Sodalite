import SwiftUI

struct HorizontalMediaRow: View {
    let title: LocalizedStringKey
    /// Rendered verbatim instead of `title` for per-library rows whose heading is a runtime string, not a localization key.
    var verbatimTitle: String? = nil
    let items: [JellyfinItem]
    let imageURLProvider: (JellyfinItem) -> URL?
    /// Per-item fallback image tried when the primary fails (e.g. series Thumb to backdrop/still).
    var fallbackURLProvider: ((JellyfinItem) -> URL?)? = nil
    var onItemSelected: ((JellyfinItem) -> Void)?
    var cardStyle: MediaCardStyle = .poster
    /// Sodalite#66. The row paints show-level art rather than each item's own still, so the cards
    /// skip the spoiler blur (Continue Watching set to Backdrop or Thumb).
    var showsSeriesArtwork: Bool = false
    /// Overrides the tier's row inset so the row can line up with a host screen that insets differently.
    var inset: CGFloat? = nil

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var rowInset: CGFloat { inset ?? metrics.rowInset }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let verbatimTitle {
                    Text(verbatimTitle)
                } else {
                    Text(title)
                }
            }
            .font(.title3)
            .fontWeight(.semibold)
            .padding(.horizontal, rowInset)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: metrics.itemSpacing) {
                    ForEach(items) { item in
                        FocusableCard {
                            onItemSelected?(item)
                        } content: { isFocused in
                            MediaCard(
                                item: item,
                                imageURL: imageURLProvider(item),
                                fallbackURL: fallbackURLProvider?(item),
                                style: cardStyle,
                                isFocused: isFocused,
                                showsSeriesArtwork: showsSeriesArtwork
                            )
                        }
                    }
                }
                .padding(.horizontal, rowInset)
                .padding(.vertical, metrics.rowVerticalPadding)
            }
            // A row is its own focus section so vertical navigation can reach it from any column (#80).
            .focusSectionCompat()
            .enrichesPosterBadges(items)
        }
    }
}
