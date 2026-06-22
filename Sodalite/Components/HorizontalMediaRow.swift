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
            .padding(.horizontal, 50)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 30) {
                    ForEach(items) { item in
                        FocusableCard {
                            onItemSelected?(item)
                        } content: { isFocused in
                            MediaCard(
                                item: item,
                                imageURL: imageURLProvider(item),
                                fallbackURL: fallbackURLProvider?(item),
                                style: cardStyle,
                                isFocused: isFocused
                            )
                        }
                    }
                }
                .padding(.horizontal, 50)
                .padding(.vertical, 20)
            }
        }
    }
}
