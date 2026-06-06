import SwiftUI

struct HorizontalMediaRow: View {
    let title: LocalizedStringKey
    /// When set, rendered verbatim instead of `title`. Used for
    /// per-library rows whose heading is a runtime string ("Latest in
    /// 4K Movies") rather than a localization key.
    var verbatimTitle: String? = nil
    let items: [JellyfinItem]
    let imageURLProvider: (JellyfinItem) -> URL?
    /// Optional per-item fallback image, tried when the primary fails
    /// (e.g. a series Thumb that falls back to the backdrop / still).
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
