import SwiftUI

struct TagRow: View {
    let title: LocalizedStringKey
    let tags: [TagCardData]
    var onTagSelected: ((TagCardData) -> Void)?

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
                    ForEach(tags) { tag in
                        GenreCard(data: tag) {
                            onTagSelected?(tag)
                        }
                    }
                }
                .padding(.horizontal, metrics.rowInset)
                .padding(.vertical, metrics.rowVerticalPadding)
            }
        }
    }
}

struct TagCardData: Identifiable, Sendable {
    let id: String
    let name: String
    let backdropURL: URL?
}

struct GenreCard: View {
    let data: TagCardData
    let action: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var tileSize: CGSize { LayoutMetrics.current(hSizeClass).genreTileSize }

    var body: some View {
        FocusableCard {
            action()
        } content: { isFocused in
            ZStack(alignment: .bottomLeading) {
                AsyncCachedImage(url: data.backdropURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.Theme.surface, Color.Theme.surfaceElevated],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .frame(width: tileSize.width, height: tileSize.height)
                .clipped()

                Rectangle()
                    .fill(.black.opacity(0.55))

                Text(data.name)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(width: tileSize.width, height: tileSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.tint, lineWidth: 4)
                    .opacity(isFocused ? 1 : 0)
            )
        }
    }
}
