import SwiftUI

// MARK: - Dropdown Item


enum DropdownImage {
    case url(URL)                 // episode picker: Jellyfin image
    case chapterThumbnail(Int)    // chapter picker: server chapter image, else FrameExtractor still
}

struct DropdownItem {
    let title: String
    let isActive: Bool
    let isHighlighted: Bool
    /// Thumbnail source: `.url` (episodes), `.chapterThumbnail` (chapters), else nil.
    var image: DropdownImage? = nil
    /// Trailing affordance caption (e.g. "Hold to delete" on external subtitle rows).
    var hint: String? = nil
    /// Pins this row as a fixed footer below the scroll list (subtitle "Search online...").
    var isPinnedFooter: Bool = false
    var separatorAbove: Bool = false
    /// Pins this row as a fixed header above the scroll list (subtitle "Secondary: ...").
    var isPinnedHeader: Bool = false
    var separatorBelow: Bool = false
}

// MARK: - The open menu

/// The open track menu, shared by both transport bars (AE#359 follow-up). Extracted from
/// `TransportBar` verbatim so the VOD bar and the Live bar cannot drift apart in row height,
/// highlight, scroll centring or transition. The chip that opens it stays with each bar: their
/// button idioms differ on purpose, VOD chips against the live capsules.
struct PlayerTrackDropdownList: View {
    let items: [DropdownItem]
    /// Chapter rows load their still lazily. nil where no bar offers chapters (live).
    var chapterThumbnail: (@Sendable (Int) async -> CGImage?)?

    private static let dropdownItemHeight: CGFloat = 56
    /// Taller row for thumbnail dropdowns (120×68 image + 8pt breathing room); text-only stays 56.
    private static let episodeRowHeight: CGFloat = 84
    private static let dropdownMaxVisible: Int = 6

    var body: some View {
            let hasImages = items.contains(where: { $0.image != nil })
            let rowHeight = hasImages ? Self.episodeRowHeight : Self.dropdownItemHeight
            // Pinned header/footer rows render outside the scroll area so they stay visible;
            // original indices are preserved so the host-driven highlight math is unaffected.
            let indexed = Array(items.enumerated())
            let headerIndexed = indexed.filter { $0.element.isPinnedHeader }
            let scrollIndexed = indexed.filter { !$0.element.isPinnedFooter && !$0.element.isPinnedHeader }
            let pinnedIndexed = indexed.filter { $0.element.isPinnedFooter }
            let visibleCount = min(scrollIndexed.count, Self.dropdownMaxVisible)
            let height = CGFloat(visibleCount) * rowHeight

            VStack(spacing: 0) {
                ForEach(headerIndexed, id: \.offset) { idx, item in
                    dropdownRow(item: item, hasImages: hasImages, rowHeight: rowHeight)
                        .id(idx)
                    if item.separatorBelow {
                        Rectangle()
                            .fill(Color.white.opacity(0.15))
                            .frame(height: 1)
                            .padding(.horizontal, 16)
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(scrollIndexed, id: \.offset) { idx, item in
                                dropdownRow(item: item, hasImages: hasImages, rowHeight: rowHeight)
                                    .id(idx)
                            }
                        }
                    }
                    .onAppear {
                        // Explicit first-render scroll; .onChange only fires on a CHANGE, not
                        // for the value the dropdown opened at, so without this the active row
                        // is offscreen (anchored at 0) until the user moves one step.
                        if let highlighted = scrollIndexed.first(where: { $0.element.isHighlighted })?.offset {
                            proxy.scrollTo(highlighted, anchor: .center)
                        }
                    }
                    .onChange(of: scrollIndexed.first(where: { $0.element.isHighlighted })?.offset) { _, highlighted in
                        if let highlighted {
                            withAnimation { proxy.scrollTo(highlighted, anchor: .center) }
                        }
                    }
                }
                .frame(height: height)

                ForEach(pinnedIndexed, id: \.offset) { idx, item in
                    if item.separatorAbove {
                        Rectangle()
                            .fill(Color.white.opacity(0.15))
                            .frame(height: 1)
                            .padding(.horizontal, 16)
                    }
                    dropdownRow(item: item, hasImages: hasImages, rowHeight: rowHeight)
                        .id(idx)
                }
            }
            // Image dropdowns get a tight width cap so long titles wrap instead of stretching
            // the column over the transport row; text-only ones get headroom so names like
            // "Deutsch · Dolby TrueHD 7.1" don't truncate.
            .frame(
                minWidth: hasImages ? 480 : 0,
                maxWidth: hasImages ? 720 : 800
            )
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .fixedSize(horizontal: true, vertical: false)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder
    private func dropdownRow(item: DropdownItem, hasImages: Bool, rowHeight: CGFloat) -> some View {
        HStack(spacing: 14) {
            if hasImages {
                Group {
                    switch item.image {
                    case .url(let url):
                        AsyncCachedImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(Color.white.opacity(0.08))
                        }
                    case .chapterThumbnail(let index):
                        ChapterThumbnailView(index: index, load: chapterThumbnail ?? { _ in nil })
                    case .none:
                        Rectangle().fill(Color.white.opacity(0.08))
                    }
                }
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text(item.title)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer()

            if let hint = item.hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(item.isHighlighted ? .white.opacity(0.7) : .white.opacity(0.4))
            }

            if item.isActive {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .fontWeight(.bold)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: rowHeight)
        .background(item.isHighlighted ? Color.white.opacity(0.25) : Color.clear)
        .foregroundStyle(item.isHighlighted ? .white : .white.opacity(0.8))
        // Glide the highlight between rows instead of snapping.
        .animation(.smooth(duration: 0.32), value: item.isHighlighted)
    }
}

// MARK: - Chapter Thumbnail View

/// Loads a chapter thumbnail on appear (server chapter image, else FrameExtractor still),
/// gray placeholder until ready. Lazy, so only visible rows load; both caches make repeats cheap.
private struct ChapterThumbnailView: View {
    let index: Int
    let load: @Sendable (Int) async -> CGImage?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.08))
            if let image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .task(id: index) {
            image = await load(index)
        }
    }
}
