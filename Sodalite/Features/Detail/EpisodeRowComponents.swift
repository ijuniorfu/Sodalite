import SwiftUI

/// Sub-components extracted from SeriesDetailView so the main file
/// stays focused on the series load/render flow and its focus
/// machinery. Lives in the same target, all of these were already
/// internal; SeasonTab receives the season-bar FocusState binding as
/// a parameter, so nothing here reaches into the view's focus state.

// MARK: - Season Tab

struct SeasonTab: View {
    let id: String
    let name: String
    let isSelected: Bool
    var focusedID: FocusState<String?>.Binding
    let action: () -> Void

    private var isFocused: Bool { focusedID.wrappedValue == id }

    var body: some View {
        Button { action() } label: {
            Text(name)
                .font(.subheadline)
                .fontWeight(isSelected ? .bold : .regular)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(tabBackground)
                )
        }
        .buttonStyle(SeasonTabButtonStyle())
        .focused(focusedID, equals: id)
    }

    private var tabBackground: Color {
        if isFocused { return .white.opacity(0.12) }
        if isSelected { return .white.opacity(0.08) }
        return .clear
    }
}

// MARK: - Button Styles

struct EpisodeCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        // Stroke is drawn inside EpisodeLandscapeCard so it hugs the
        // thumbnail only, not the title/runtime row below.
        configuration.label
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 20, y: 10)
            .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}

struct SeasonTabButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        // Asymmetric animation on the stroke: 50 ms delay on fade-in,
        // zero delay on fade-out. If any residual wrong-tab-first
        // transition slips past the onMoveCommand prime (first entry
        // into the view, an edge-case direction), the stroke simply
        // never becomes visible on the wrong tab, the 50 ms window
        // is enough for the DispatchQueue fallback to land focus on
        // the right tab first. Between-tab navigation still feels
        // instant because 50 ms is sub-perceptual.
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
                    .animation(
                        isFocused
                            ? .easeIn(duration: 0.15).delay(0.05)
                            : .easeOut(duration: 0.1),
                        value: isFocused
                    )
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Episode Landscape Card

/// Loading placeholder mirroring EpisodeLandscapeCard's 360x202 thumbnail
/// plus the two caption lines. A single horizontally sweeping highlight
/// reads as "loading" without the cost of per-card animation state, the
/// phase is driven from one `@State` that all cards in the row share via
/// the same `.onAppear` animation.
struct EpisodeSkeletonCard: View {
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.Theme.surface)
                .frame(width: 360, height: 202)
                .overlay(shimmerOverlay.clipShape(RoundedRectangle(cornerRadius: 12)))

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.Theme.surface)
                    .frame(width: 220, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.Theme.surface)
                    .frame(width: 90, height: 11)
            }
            .frame(width: 360, alignment: .leading)

            // Synopsis-box placeholder mirroring EpisodeSynopsisBox's padded
            // three-line height, so the row keeps its height when the real
            // episodes (card + synopsis box) replace the skeleton.
            Text(" ")
                .font(.caption)
                .lineLimit(3, reservesSpace: true)
                .frame(width: 332, alignment: .topLeading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.Theme.surface))
                .overlay(shimmerOverlay.clipShape(RoundedRectangle(cornerRadius: 12)))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                shimmer = true
            }
        }
    }

    private var shimmerOverlay: some View {
        LinearGradient(
            colors: [.clear, Color.white.opacity(0.08), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 180)
        .offset(x: shimmer ? 360 : -180)
    }
}

struct EpisodeLandscapeCard: View {
    let episode: JellyfinItem
    let imageURL: URL?
    var isSelected: Bool = false
    var isCurrent: Bool = false

    /// Set by the caller based on the surrounding `@FocusState`
    /// (`focusedEpisodeID == episode.id`). Drives the accent-colored
    /// focus stroke on the thumbnail, `@Environment(\.isFocused)` in
    /// a Button label is unreliable on tvOS, so we pass it explicitly.
    var isFocused: Bool = false

    /// Played state passed explicitly by the caller so the badge can
    /// live-update from the view model's override map (the immutable
    /// `episode.userData` snapshot would never change in-session).
    var isPlayed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                AsyncCachedImage(url: imageURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.Theme.surface)
                        .overlay(
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 30))
                                .foregroundStyle(.tertiary)
                        )
                }
                .frame(width: 360, height: 202)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    // Outer stroke, same pattern as MediaCard. Keeps
                    // the thumbnail itself clean (no inner bite) and
                    // leaves the 4pt progress bar fully visible.
                    RoundedRectangle(cornerRadius: 12 + strokeWidth)
                        .strokeBorder(strokeStyle, lineWidth: strokeWidth)
                        .padding(-strokeWidth)
                        .animation(.easeInOut(duration: 0.2), value: isFocused)
                )

                if let pct = episode.userData?.playedPercentage, pct > 0 {
                    GeometryReader { geo in
                        VStack {
                            Spacer()
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.ultraThinMaterial).frame(height: 6)
                                Rectangle().fill(Color.white.opacity(0.9)).frame(width: geo.size.width * pct / 100, height: 6)
                            }
                        }
                    }
                    .frame(width: 360, height: 202)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if isPlayed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: 360, height: 202)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let ep = episode.indexNumber {
                        Text("E\(ep)")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .fontWeight(.semibold)
                    }
                    Text(episode.name)
                        .font(.caption)
                        .lineLimit(1)
                }

                if let runtime = episode.runTimeTicks {
                    Text(runtime.ticksToDisplay)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 360, alignment: .leading)
        }
    }

    /// Focus stroke beats selected and current, when the user is
    /// interacting with the card, that trumps whatever state it's in.
    /// AnyShapeStyle lets us mix the tint ShapeStyle (focus) with plain
    /// Color values (selected/current) behind the same .strokeBorder.
    private var strokeStyle: AnyShapeStyle {
        if isFocused { return AnyShapeStyle(TintShapeStyle.tint) }
        if isSelected { return AnyShapeStyle(TintShapeStyle.tint.opacity(0.8)) }
        if isCurrent { return AnyShapeStyle(Color.green.opacity(0.8)) }
        return AnyShapeStyle(Color.clear)
    }

    private var strokeWidth: CGFloat {
        if isFocused { return 3 }
        return isCurrent ? 3 : 2
    }
}

// MARK: - Episode Synopsis Box

/// Navigable synopsis box that sits under an episode card. Mirrors the
/// series-level `ExpandableTextBox`: focus it and tap to open the full
/// episode overview as a `TextOverlay`. It always reserves a three-line
/// height (via `reservesSpace: true`) so every column in the episode row
/// stays the same height. When an episode has no overview the box renders
/// as transparent, non-focusable, reserved space, so cards stay uniform
/// without leaving a focusable-but-empty dead end.
struct EpisodeSynopsisBox: View {
    let text: String
    @State private var showFullText = false
    @FocusState private var isFocused: Bool

    private var hasText: Bool { !text.isEmpty }

    var body: some View {
        Group {
            if hasText {
                Text(text)
            } else {
                // Visible placeholder instead of an invisible spacer:
                // columns whose episode has no overview otherwise look
                // broken next to filled ones (Sodalite#15). Stays
                // non-focusable, there is nothing to expand.
                Text("detail.noDescription")
                    .italic()
            }
        }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3, reservesSpace: true)
            .multilineTextAlignment(.leading)
            .frame(width: 332, alignment: .topLeading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                // Material base for the full-bleed backdrop redesign,
                // same rationale as ExpandableTextBox.
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isFocused ? .white.opacity(0.12) : .clear)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .focusable(hasText)
            .focused($isFocused)
            .stableTap(isFocused: isFocused) {
                guard hasText else { return }
                showFullText = true
            }
            .fullScreenCover(isPresented: $showFullText) {
                TextOverlay(text: text, isPresented: $showFullText)
            }
    }
}
