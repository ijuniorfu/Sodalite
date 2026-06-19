import SwiftUI

enum MediaCardStyle: Sendable {
    case poster    // Vertical 2:3 (movies, series)
    case landscape // Horizontal 16:9 (episodes, continue watching)
    case square    // 1:1 (album / music covers)
}

struct MediaCard: View {
    let item: JellyfinItem
    let imageURL: URL?
    /// Tried when `imageURL` is nil or fails (e.g. a series Thumb that
    /// falls back to the backdrop / episode still for Continue Watching).
    let fallbackURL: URL?
    let style: MediaCardStyle

    /// Set by the caller, either forwarded from `FocusableCard`'s
    /// content closure or derived from a surrounding `@FocusState`
    /// (`focusedID == item.id`). tvOS's `@Environment(\.isFocused)`
    /// doesn't propagate reliably through Button labels, so we pass
    /// it explicitly.
    let isFocused: Bool

    @Environment(\.dependencies) private var dependencies

    /// Apple TV-style enlarge factor from Appearance settings (1.0 normal).
    /// Applied to every style so rows stay proportional to each other.
    private var scale: CGFloat { dependencies.appearancePreferences.cardScale }

    private var cardWidth: CGFloat {
        let base: CGFloat = switch style {
        case .poster: 220
        case .landscape: 360
        case .square: 220
        }
        return base * scale
    }

    private var cardHeight: CGFloat {
        let base: CGFloat = switch style {
        case .poster: 330
        case .landscape: 202
        case .square: 220
        }
        return base * scale
    }

    init(
        item: JellyfinItem,
        imageURL: URL?,
        fallbackURL: URL? = nil,
        style: MediaCardStyle = .poster,
        isFocused: Bool = false
    ) {
        self.item = item
        self.imageURL = imageURL
        self.fallbackURL = fallbackURL
        self.style = style
        self.isFocused = isFocused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            posterImage
            itemInfo
        }
        .frame(width: cardWidth)
    }

    private var posterImage: some View {
        AsyncCachedImage(url: imageURL, fallbackURL: fallbackURL) { image in
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
        .overlay(alignment: .bottom) {
            progressOverlay
        }
        .overlay(alignment: .topTrailing) {
            if item.userData?.played == true {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .padding(10)
            }
        }
        .overlay(
            // Outer stroke, padding(-3) pushes the overlay frame 3pt
            // past the image edge, so the border sits *around* the card
            // rather than eating into it. Outer corner radius is
            // card radius + stroke width so the curve stays concentric.
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(.tint, lineWidth: 3)
                .padding(-3)
                .opacity(isFocused ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: isFocused)
        )
    }

    private var itemInfo: some View {
        // Always render the subtitle slot, even with an empty
        // string, so cards in a row stay the same total height.
        // Otherwise items without a subtitle (BoxSets without a
        // year, episodes from very thinly-scraped libraries) make
        // the row's vertical centering kick in and the titles end
        // up at staggered y-positions next to neighbouring cards.
        VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
                .font(.caption)
                .lineLimit(1)

            Text(displaySubtitle ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var displayTitle: String {
        if style == .landscape, item.type == .episode {
            if let ep = item.indexNumber {
                return "E\(ep) · \(item.name)"
            }
        }
        return item.name
    }

    private var displaySubtitle: String? {
        if item.type == .episode, let seriesName = item.seriesName {
            if let season = item.parentIndexNumber {
                return "\(seriesName) · S\(season)"
            }
            return seriesName
        }
        if let year = item.productionYear {
            return String(year)
        }
        return nil
    }

    @ViewBuilder
    private var progressOverlay: some View {
        if let playedPercentage = item.userData?.playedPercentage, playedPercentage > 0 {
            GeometryReader { geo in
                VStack {
                    Spacer()
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .frame(height: 10)
                        Rectangle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: geo.size.width * playedPercentage / 100, height: 10)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var iconForType: String {
        switch item.type {
        case .movie: "film"
        case .series: "tv"
        case .episode: "play.rectangle"
        case .season: "tv"
        case .musicAlbum, .audio: "music.note"
        default: "photo"
        }
    }
}
