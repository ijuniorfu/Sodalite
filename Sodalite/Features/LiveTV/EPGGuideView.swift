import SwiftUI

/// The EPG guide grid: a pinned channel column on the left, a pinned time
/// header on top, and a 2D-scrollable program area.
///
/// Layout model: a single program `ScrollView` is the source of scroll
/// truth. Its content is inset by the channel-column width (leading) and the
/// header height (top), so programs never sit under the pinned column. The
/// channel column and time header are overlays on top of the scroll view; we
/// observe the scroll content offset via `onScrollGeometryChange` and shift
/// the column by the vertical offset and the header by the horizontal offset,
/// so both stay in lockstep with the grid (including tvOS focus-driven
/// auto-scroll, which moves the same offset).
struct EPGGuideView: View {
    @State private var model: EPGGuideViewModel
    @Environment(\.dependencies) private var dependencies
    @State private var selectedProgram: JellyfinProgram?
    @State private var selectedChannel: JellyfinChannel?
    /// Live content offset of the program ScrollView, mirrored from
    /// `onScrollGeometryChange`. Drives the pinned column / header offsets.
    @State private var scrollOffset = CGPoint.zero
    var onWatchLive: ((LivePlaybackContext) -> Void)?

    /// Height reserved for the pinned time header above the program rows.
    private let headerHeight: CGFloat = 60

    private var columnWidth: CGFloat { EPGGuideViewModel.channelColumnWidth }

    init(model: EPGGuideViewModel, onWatchLive: ((LivePlaybackContext) -> Void)? = nil) {
        _model = State(initialValue: model)
        self.onWatchLive = onWatchLive
    }

    private var tint: Color {
        dependencies.appearancePreferences.effectiveTint(
            isSupporter: dependencies.storeKitService.isSupporter
        ) ?? Color.accentColor
    }

    var body: some View {
        Group {
            if model.channels.isEmpty && model.isLoadingChannels {
                ProgressView()
            } else if model.channels.isEmpty, let err = model.loadError {
                ContentUnavailableView(
                    "livetv.loadFailed.title",
                    systemImage: "tv.slash",
                    description: Text(err))
            } else {
                guideBody
            }
        }
        .task { await model.loadInitialChannels() }
        .sheet(item: $selectedProgram) { program in
            if let channel = selectedChannel {
                ProgramInfoPopover(program: program, channel: channel, tint: tint, onWatchLive: onWatchLive)
            }
        }
    }

    private var guideBody: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                programScroll
                pinnedChannelColumn(height: geo.size.height)
                pinnedTimeHeader(width: geo.size.width)
                corner
            }
        }
    }

    // MARK: - Program scroll (source of truth)

    private var programScroll: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.channels) { channel in
                    programRow(for: channel)
                        .frame(width: model.totalWidth, height: EPGGuideViewModel.rowHeight)
                        .task { await loadProgramsAround(channel) }
                }
            }
            // Inset so programs sit to the right of the column and below the
            // header. The pinned overlays cover these insets.
            .padding(.leading, columnWidth)
            .padding(.top, headerHeight)
            .overlay(alignment: .topLeading) {
                nowLine
            }
        }
        .onScrollGeometryChange(for: CGPoint.self) { geometry in
            geometry.contentOffset
        } action: { _, newValue in
            scrollOffset = newValue
        }
    }

    private func programRow(for channel: JellyfinChannel) -> some View {
        let programs = model.programsByChannel[channel.id] ?? []
        return ZStack(alignment: .leading) {
            if programs.isEmpty {
                EPGPlaceholderCell(width: model.totalWidth, tint: tint) {
                    select(program: synthesizedProgram(for: channel), channel: channel)
                }
            } else {
                ForEach(programs) { program in
                    if let start = program.startDate, let end = program.endDate {
                        EPGProgramCell(
                            program: program,
                            width: model.width(start: start, end: end),
                            tint: tint
                        ) { select(program: program, channel: channel) }
                        .offset(x: model.xOffset(for: start))
                    }
                }
            }
        }
        .frame(width: model.totalWidth, alignment: .leading)
    }

    private var nowLine: some View {
        Rectangle()
            .fill(Color.red)
            .frame(width: 2)
            .offset(x: columnWidth + model.xOffset(for: Date()))
            .allowsHitTesting(false)
    }

    // MARK: - Pinned channel column (tracks vertical scroll)

    private func pinnedChannelColumn(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(model.channels) { channel in
                channelCell(channel)
                    .frame(width: columnWidth, height: EPGGuideViewModel.rowHeight)
            }
        }
        // Shift down by the header height (to clear the header band) and up by
        // the program scroll's vertical offset (to track it).
        .offset(y: headerHeight - scrollOffset.y)
        .frame(width: columnWidth, height: height, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    private func channelCell(_ channel: JellyfinChannel) -> some View {
        HStack(spacing: 12) {
            channelLogo(channel)
            VStack(alignment: .leading) {
                Text(channel.name).font(.headline).lineLimit(1)
                if let num = channel.channelNumber {
                    Text(num).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func channelLogo(_ channel: JellyfinChannel) -> some View {
        if let url = dependencies.jellyfinImageService.imageURL(
            itemID: channel.id, imageType: .primary, tag: channel.primaryImageTag, maxHeight: 64) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "tv").foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 56)
        } else {
            Image(systemName: "tv").frame(width: 56, height: 56).foregroundStyle(.secondary)
        }
    }

    // MARK: - Pinned time header (tracks horizontal scroll)

    private func pinnedTimeHeader(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(model.timeTicks, id: \.self) { tick in
                Text(tick.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                    .offset(x: columnWidth + model.xOffset(for: tick) + 6)
            }
        }
        .frame(width: width, height: headerHeight, alignment: .leading)
        .offset(x: -scrollOffset.x)
        .frame(width: width, height: headerHeight, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipped()
        .allowsHitTesting(false)
    }

    /// Opaque cover for the top-left intersection of column and header.
    private var corner: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(width: columnWidth, height: headerHeight)
            .allowsHitTesting(false)
    }

    // MARK: - Actions / data

    private func select(program: JellyfinProgram, channel: JellyfinChannel) {
        selectedChannel = channel
        selectedProgram = program
    }

    private func synthesizedProgram(for channel: JellyfinChannel) -> JellyfinProgram {
        JellyfinProgram(
            id: "live-\(channel.id)", channelId: channel.id, name: channel.name,
            overview: nil, startDate: Date().addingTimeInterval(-1),
            endDate: Date().addingTimeInterval(3600), genres: nil, imageTags: nil,
            isLive: true, isNews: nil, isMovie: nil, isSeries: nil)
    }

    private func loadProgramsAround(_ channel: JellyfinChannel) async {
        guard let idx = model.channels.firstIndex(of: channel) else { return }
        let slice = model.channels[idx..<min(idx + 6, model.channels.count)]
        await model.ensurePrograms(for: slice.map(\.id))
        if idx >= model.channels.count - 3 {
            await model.loadMoreChannels()
        }
    }
}
