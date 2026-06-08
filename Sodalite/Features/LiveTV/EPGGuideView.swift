import SwiftUI

/// The EPG guide grid: a sticky channel column on the left, a sticky time
/// header on top, and a 2D-scrollable program area. Consumes
/// `EPGGuideViewModel` for layout math and data, and renders
/// `EPGProgramCell` / `EPGPlaceholderCell` blocks.
///
/// Known limitation: keeping the sticky channel column and time header
/// perfectly scroll-synced with the 2D program ScrollView on tvOS is an
/// open problem (top UI risk in the design). The structure here is
/// approximately correct; exact scroll coupling is iterated on-device.
struct EPGGuideView: View {
    @State private var model: EPGGuideViewModel
    @Environment(\.dependencies) private var dependencies
    @State private var selectedProgram: JellyfinProgram?
    @State private var selectedChannel: JellyfinChannel?

    /// Height reserved for the sticky time header above the program rows.
    private let headerHeight: CGFloat = 44

    init(model: EPGGuideViewModel) {
        _model = State(initialValue: model)
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
            // TODO: replace stub with ProgramInfoPopover in Task 9
            VStack(alignment: .leading, spacing: 16) {
                Text(program.name).font(.title)
                if let start = program.startDate, let end = program.endDate {
                    Text("\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
                if let overview = program.overview { Text(overview) }
            }
            .padding(60)
        }
    }

    private var guideBody: some View {
        HStack(spacing: 0) {
            channelColumn
                .frame(width: EPGGuideViewModel.channelColumnWidth)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    timeHeader
                    ForEach(model.channels) { channel in
                        programRow(for: channel)
                            .frame(height: EPGGuideViewModel.rowHeight)
                            .task { await loadProgramsAround(channel) }
                    }
                }
                .overlay(alignment: .topLeading) { nowLine }
            }
        }
    }

    private var channelColumn: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                Color.clear.frame(height: headerHeight)
                ForEach(model.channels) { channel in
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
                    .frame(height: EPGGuideViewModel.rowHeight)
                }
            }
        }
        .scrollDisabled(true)
    }

    @ViewBuilder
    private func channelLogo(_ channel: JellyfinChannel) -> some View {
        if let url = dependencies.jellyfinImageService.imageURL(
            itemID: channel.id, imageType: .primary, tag: channel.primaryImageTag, maxHeight: 80) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "tv").foregroundStyle(.secondary)
            }
            .frame(width: 64, height: 64)
        } else {
            Image(systemName: "tv").frame(width: 64, height: 64).foregroundStyle(.secondary)
        }
    }

    private var timeHeader: some View {
        ZStack(alignment: .leading) {
            ForEach(model.timeTicks, id: \.self) { tick in
                Text(tick.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                    .offset(x: model.xOffset(for: tick) + 6)
            }
        }
        .frame(width: model.totalWidth, height: headerHeight, alignment: .leading)
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
            .offset(x: model.xOffset(for: Date()))
            .padding(.top, headerHeight)
            .allowsHitTesting(false)
    }

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
