import SwiftUI

struct SeerrMediaCard: View {
    let media: SeerrMedia
    /// Passed by the caller (same pattern as `MediaCard`); drives the focus stroke.
    var isFocused: Bool = false

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var cardWidth: CGFloat { LayoutMetrics.current(hSizeClass).posterSize.width }
    private var cardHeight: CGFloat { LayoutMetrics.current(hSizeClass).posterSize.height }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            posterImage
            itemInfo
        }
        .frame(width: cardWidth)
    }

    private var posterImage: some View {
        AsyncCachedImage(url: SeerrImageURL.poster(path: media.posterPath)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Rectangle()
                    .fill(Color.Theme.surface)
                Image(systemName: iconForType)
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Bounded for the same reason as MediaCard's poster: a fill-scaled image overflows its
        // frame, and the clip above is visual only, so the invisible part stays tappable and
        // covers the neighbour drawn before it (discussion #98).
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            if let status = media.mediaInfo?.status, status != .unknown {
                SeerrStatusBadge(status: status, compact: true)
                    .padding(8)
            }
        }
        .overlay(
            MediaFocusRing(
                shape: RoundedRectangle(cornerRadius: 16),
                isFocused: isFocused
            )
        )
    }

    private var itemInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(media.displayTitle)
                .font(.caption)
                .lineLimit(1)

            if let year = media.displayYear {
                Text(year)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var iconForType: String {
        switch media.mediaType {
        case .movie: "film"
        case .tv: "tv"
        case .person, .unknown: "person"
        }
    }
}
