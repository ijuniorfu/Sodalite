import SwiftUI

/// Bundles the tapped program + its (real or synthesized) channel so the
/// info sheet receives both atomically (same race fix as EPGSelection).
private struct ProgramSelection: Identifiable {
    let channel: JellyfinChannel
    let program: JellyfinProgram
    var id: String { "\(channel.id)-\(program.id)" }
}

/// Live TV "Übersicht": recommended programs in category rows. Reuses the shared `EPGGuideViewModel`
/// for record/favorite/timer state so the optimistic overlay stays consistent across segments.
struct LiveProgramsView: View {
    @State private var model: LiveProgramsViewModel
    let guideModel: EPGGuideViewModel
    let tint: Color
    var onWatchLive: ((LivePlaybackContext) -> Void)?

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var selection: ProgramSelection?

    init(model: LiveProgramsViewModel,
         guideModel: EPGGuideViewModel,
         tint: Color,
         onWatchLive: ((LivePlaybackContext) -> Void)? = nil) {
        _model = State(initialValue: model)
        self.guideModel = guideModel
        self.tint = tint
        self.onWatchLive = onWatchLive
    }

    var body: some View {
        Group {
            if model.rows.isEmpty && model.isLoading {
                ProgressView()
            } else if model.rows.isEmpty, let err = model.loadError {
                ContentUnavailableView(
                    "livetv.loadFailed.title",
                    systemImage: "tv.slash",
                    description: Text(err))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: hSizeClass == .compact ? 24 : 40) {
                        ForEach(LiveProgramCategory.allCases) { category in
                            if let programs = model.rows[category], !programs.isEmpty {
                                ProgramCategoryRow(
                                    titleKey: category.titleKey,
                                    programs: programs,
                                    tint: tint,
                                    imageURLProvider: { program in
                                        dependencies.jellyfinImageService.imageURL(
                                            itemID: program.id, imageType: .primary,
                                            tag: program.primaryImageTag, maxWidth: 360)
                                    },
                                    onSelect: { program in
                                        guard let channel = model.channel(
                                            for: program, guideChannels: guideModel.channels)
                                        else { return }
                                        selection = ProgramSelection(channel: channel, program: program)
                                    }
                                )
                            }
                        }
                    }
                    .padding(.vertical, hSizeClass == .compact ? 16 : 40)
                }
            }
        }
        .task { await model.load() }
        // Full-screen cover, NOT .sheet: a tvOS sheet leaves the tab bar visible behind it and tvOS 26 re-templates the backgrounded bar gray. The cover covers the bar so it is never disturbed.
        .detailCover(item: $selection) { sel in
            ProgramInfoPopover(
                program: sel.program, channel: sel.channel, tint: tint,
                onWatchLive: onWatchLive,
                channelIsFavorite: guideModel.isFavorite(sel.channel.id),
                onToggleFavorite: { guideModel.toggleFavorite(channelID: sel.channel.id) },
                hasTimer: guideModel.effectiveTimerState(for: sel.program).timerId != nil,
                hasSeriesTimer: guideModel.effectiveTimerState(for: sel.program).seriesTimerId != nil,
                onToggleRecord: { guideModel.toggleRecord(program: sel.program) },
                onToggleSeriesRecord: { guideModel.toggleSeriesRecord(program: sel.program) })
            .alert(
                Text("livetv.recording.error.title"),
                isPresented: Binding(
                    get: { guideModel.recordingError != nil },
                    set: { if !$0 { guideModel.recordingError = nil } }
                )
            ) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text(guideModel.recordingError ?? "")
            }
        }
    }
}

/// One category row: title above a horizontal scroll of `ProgramCard`s. Mirrors `HorizontalMediaRow`.
private struct ProgramCategoryRow: View {
    let titleKey: LocalizedStringKey
    let programs: [JellyfinProgram]
    let tint: Color
    let imageURLProvider: (JellyfinProgram) -> URL?
    let onSelect: (JellyfinProgram) -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titleKey)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, metrics.rowInset)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: metrics.itemSpacing) {
                    ForEach(programs) { program in
                        FocusableCard {
                            onSelect(program)
                        } content: { isFocused in
                            ProgramCard(
                                program: program,
                                imageURL: imageURLProvider(program),
                                isFocused: isFocused)
                        }
                    }
                }
                .padding(.horizontal, metrics.rowInset)
                .padding(.vertical, metrics.rowVerticalPadding)
            }
        }
    }
}

/// 16:9 program card (mirrors `MediaCard.landscape`, 360x202): image + TV placeholder, tinted focus
/// stroke, title + channel/time subtitle (always rendered so cards in a row stay equal height).
private struct ProgramCard: View {
    let program: JellyfinProgram
    let imageURL: URL?
    let isFocused: Bool

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var cardWidth: CGFloat { LayoutMetrics.current(hSizeClass).landscapeSize.width }
    private var cardHeight: CGFloat { LayoutMetrics.current(hSizeClass).landscapeSize.height }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncCachedImage(url: imageURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Rectangle().fill(Color.Theme.surface)
                    Image(systemName: "tv")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(-3)
                    .opacity(isFocused ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: isFocused)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(program.name)
                    .font(.caption)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: cardWidth)
    }

    private var subtitle: String {
        let channel = program.channelName ?? ""
        if let start = program.startDate {
            let time = start.formatted(date: .omitted, time: .shortened)
            return channel.isEmpty ? time : "\(channel) · \(time)"
        }
        return channel.isEmpty ? " " : channel
    }
}
