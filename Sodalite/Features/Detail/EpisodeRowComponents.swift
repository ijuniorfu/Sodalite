import SwiftUI

/// Sub-components extracted from SeriesDetailView. SeasonTab receives the season-bar FocusState as a parameter, so nothing here reaches into the view's focus state.

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
        // Stroke drawn inside EpisodeLandscapeCard so it hugs the thumbnail only, not the caption below.
        configuration.label
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 20, y: 10)
            .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}

struct SeasonTabButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        // Asymmetric stroke: 50ms fade-in delay, 0 fade-out. A residual wrong-tab transition slipping past the onMoveCommand prime never shows the stroke, the 50ms window lets the DispatchQueue fallback land focus on the right tab first. 50ms is sub-perceptual.
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

/// Loading placeholder mirroring EpisodeLandscapeCard's 360x202 thumbnail + caption lines, with one sweeping highlight.
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

            // Synopsis placeholder at EpisodeSynopsisBox's three-line height so the row keeps its height on swap.
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

    /// Passed explicitly (focusedEpisodeID == episode.id): @Environment(\.isFocused) in a Button label is unreliable on tvOS.
    var isFocused: Bool = false

    /// Passed explicitly so the badge live-updates from the VM override map (the immutable episode.userData wouldn't change in-session).
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
                    // Outer stroke (MediaCard pattern): no inner bite, leaves the progress bar fully visible.
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
                                Rectangle().fill(.ultraThinMaterial).frame(height: 10)
                                Rectangle().fill(Color.white.opacity(0.9)).frame(width: geo.size.width * pct / 100, height: 10)
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

    /// Focus stroke beats selected/current. AnyShapeStyle mixes the tint ShapeStyle (focus) with Color values (selected/current) behind one .strokeBorder.
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

/// Navigable per-card synopsis box (mirrors ExpandableTextBox). Always reserves three lines so columns stay equal height; an overview-less episode renders non-focusable reserved space, no focusable-but-empty dead end.
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
                // Visible placeholder, not an invisible spacer: an overview-less column looks broken next to filled ones (Sodalite#15). Non-focusable, nothing to expand.
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
                // Material base for the full-bleed backdrop redesign (ExpandableTextBox rationale).
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
