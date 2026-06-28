#if os(iOS)
import SwiftUI
import AetherEngine

/// Purpose-built touch controls for the iOS/iPadOS player. Custom, tinted, matching the tvOS look,
/// but designed for touch (no focus model): top bar (close + title), a bottom block with a drag
/// scrubber, a centered play/pause, and a tinted icon row whose items open compact tinted pickers.
/// Drives the shared PlayerViewModel directly; the screen gestures live in PlayerGestureCatcher below.
struct PlayerTouchControls: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void
    var tintColor: Color?
    var episodeImageURL: (JellyfinItem) -> URL? = { _ in nil }
    var chapterThumbnail: (Int) async -> CGImage? = { _ in nil }

    @State private var activePicker: PickerKind?
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isPad: Bool { hSizeClass == .regular }

    private enum PickerKind: Identifiable {
        case audio, subtitle, secondarySubtitle, speed, picture, episodes, chapters
        var id: Int { hashValue }
    }

    private var tint: Color { tintColor ?? .accentColor }

    var body: some View {
        ZStack {
            // Bottom scrim so the controls stay legible over bright frames.
            VStack {
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 260)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBlock
            }
            .padding(.horizontal, isPad ? 40 : 20)
            .padding(.vertical, isPad ? 28 : 14)

            if let picker = activePicker {
                // Tap-catching scrim that closes only the picker.
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { activePicker = nil }
                pickerPanel(picker)
            }
        }
        .tint(tint)
        .foregroundStyle(.white)
        // Keep the controls up while a picker is open; re-arm the auto-hide when it closes.
        .onChange(of: activePicker) { _, newValue in
            if newValue == nil { viewModel.scheduleControlsHide() }
            else { viewModel.cancelControlsHide() }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            // Defer to the next runloop: dismissing the presenting modal synchronously from inside
            // this SwiftUI button (a child of that modal) leaves it half-closed (stream stops, modal
            // stays). Deferring lets the tap handler return first, then the dismiss completes.
            Button { DispatchQueue.main.async { onDismiss() } } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let sub = subtitleText {
                    Text(sub)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }

    private var titleText: String {
        viewModel.item.seriesName ?? viewModel.item.name
    }

    private var subtitleText: String? {
        if viewModel.item.seriesName != nil { return viewModel.item.name }
        if let year = viewModel.item.productionYear { return String(year) }
        return nil
    }

    // MARK: - Bottom block

    private var bottomBlock: some View {
        VStack(spacing: 14) {
            if viewModel.isScrubbing, let image = viewModel.scrubPreview.previewImage {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: isPad ? 150 : 110)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.18), lineWidth: 1))
            }

            iconRow

            scrubber

            HStack {
                Text(viewModel.currentTime)
                    .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.75))
                Spacer()
                Button { viewModel.togglePlayPause() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(viewModel.remainingTime)
                    .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    // MARK: - Icon row

    private var iconRow: some View {
        HStack(spacing: isPad ? 28 : 20) {
            Spacer()
            if viewModel.isInsideIntro {
                iconButton("forward.end.fill") { viewModel.skipIntro() }
            }
            if viewModel.seasonEpisodes.count > 1 {
                iconButton("list.bullet") { activePicker = .episodes }
            }
            if viewModel.chapters.count > 1, viewModel.seasonEpisodes.count <= 1 {
                iconButton("list.dash") { activePicker = .chapters }
            }
            if !viewModel.displayAudioTracks.isEmpty {
                iconButton("speaker.wave.2") { activePicker = .audio }
            }
            if !viewModel.displaySubtitleStreams.isEmpty || viewModel.supportsSubtitleSearch {
                iconButton("captions.bubble") { activePicker = .subtitle }
            }
            iconButton("gauge.with.needle") { activePicker = .speed }
            iconButton(pictureIcon) { activePicker = .picture }
            if viewModel.preferences.showStatsForNerds {
                iconButton("info.circle", active: viewModel.showStatsOverlay) {
                    viewModel.showStatsOverlay.toggle()
                }
            }
            Spacer()
        }
    }

    private func iconButton(_ systemImage: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button { action(); viewModel.showControlsTemporarily() } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(active ? tint : .white)
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pictureIcon: String {
        switch viewModel.pictureMode {
        case .original: return "rectangle.ratio.16.to.9"
        case .fill: return "rectangle.expand.vertical"
        }
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let frac = CGFloat(viewModel.displayedProgress)
            let knobX = max(0, min(width, width * frac))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 6)
                Capsule().fill(tint).frame(width: knobX, height: 6)
                Circle().fill(tint)
                    .frame(width: viewModel.isScrubbing ? 22 : 16, height: viewModel.isScrubbing ? 22 : 16)
                    .offset(x: knobX - (viewModel.isScrubbing ? 11 : 8))
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        viewModel.scrub(toFraction: Float(max(0, min(1, value.location.x / max(width, 1)))))
                    }
                    .onEnded { _ in viewModel.commitScrub() }
            )
            .animation(.easeInOut(duration: 0.15), value: viewModel.isScrubbing)
        }
        .frame(height: 28)
    }

    // MARK: - Picker panel

    private func pickerPanel(_ picker: PickerKind) -> some View {
        let panelRows = rows(for: picker)
        let hasThumbs = panelRows.contains { $0.imageURL != nil || $0.chapterIndex != nil }
        let rowHeight: CGFloat = hasThumbs ? 56 : 44
        return VStack {
            Spacer()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(panelRows.enumerated()), id: \.offset) { _, row in
                        Button {
                            if let submenu = row.opensSubmenu {
                                activePicker = submenu
                            } else {
                                row.action()
                                activePicker = nil
                            }
                        } label: {
                            HStack(spacing: 12) {
                                thumbnail(for: row)
                                Text(row.label)
                                    .foregroundStyle(row.isActive ? tint : .white)
                                    .lineLimit(1)
                                Spacer()
                                if row.isActive {
                                    Image(systemName: "checkmark").foregroundStyle(tint)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(height: rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // Size to content (capped) so a 2-track audio menu is not a tall empty panel.
            .frame(maxHeight: min(CGFloat(panelRows.count) * rowHeight, 280))
            .frame(maxWidth: hasThumbs ? (isPad ? 520 : 420) : (isPad ? 420 : 320))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .padding(.bottom, isPad ? 150 : 120)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func thumbnail(for row: PickerRow) -> some View {
        if let url = row.imageURL {
            AsyncCachedImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.white.opacity(0.1)
            }
            .frame(width: 64, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let idx = row.chapterIndex {
            ChapterThumb(index: idx, load: chapterThumbnail)
                .frame(width: 64, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private struct PickerRow {
        let label: String
        let isActive: Bool
        var imageURL: URL? = nil
        var chapterIndex: Int? = nil
        var opensSubmenu: PickerKind? = nil
        let action: () -> Void
    }

    private func rows(for picker: PickerKind) -> [PickerRow] {
        switch picker {
        case .audio:
            return viewModel.displayAudioTracks.map { track in
                PickerRow(label: TrackDisplayFormatter.shortName(for: track),
                          isActive: track.id == viewModel.activeAudioIndex) {
                    viewModel.selectAudioTrack(id: track.id)
                }
            }
        case .subtitle:
            var rows: [PickerRow] = []
            // Secondary entry at the top, matching the tvOS dropdown header.
            if !viewModel.secondarySubtitleCandidates.isEmpty {
                let secondaryLabel: String
                if let sidx = viewModel.activeSecondarySubtitleIndex,
                   let stream = viewModel.secondarySubtitleCandidates.first(where: { $0.index == sidx }) {
                    secondaryLabel = String(format: String(localized: "player.subtitle.secondary.value", defaultValue: "Secondary: %@"),
                                            TrackDisplayFormatter.subtitleStreamDisplayName(for: stream))
                } else {
                    secondaryLabel = String(localized: "player.subtitle.secondary.none", defaultValue: "Secondary: Off")
                }
                rows.append(PickerRow(label: secondaryLabel,
                                      isActive: viewModel.activeSecondarySubtitleIndex != nil,
                                      opensSubmenu: .secondarySubtitle) {})
            }
            rows.append(PickerRow(label: String(localized: "player.subtitles.off", defaultValue: "Off"),
                                  isActive: viewModel.activeSubtitleIndex == nil) {
                viewModel.selectSubtitleTrack(id: nil)
            })
            rows += viewModel.displaySubtitleStreams.map { stream in
                PickerRow(label: TrackDisplayFormatter.subtitleStreamDisplayName(for: stream),
                          isActive: stream.index == viewModel.activeSubtitleIndex) {
                    viewModel.selectSubtitleTrack(id: stream.index)
                }
            }
            if viewModel.supportsSubtitleSearch {
                rows.append(PickerRow(label: String(localized: "player.subtitles.searchOnline", defaultValue: "Search online..."), isActive: false) {
                    viewModel.presentSubtitleSearch()
                })
            }
            return rows
        case .secondarySubtitle:
            var rows: [PickerRow] = [
                PickerRow(label: String(localized: "player.subtitles.off", defaultValue: "Off"),
                          isActive: viewModel.activeSecondarySubtitleIndex == nil) {
                    viewModel.selectSecondarySubtitleTrack(id: nil)
                }
            ]
            rows += viewModel.secondarySubtitleCandidates.map { stream in
                PickerRow(label: TrackDisplayFormatter.subtitleStreamDisplayName(for: stream),
                          isActive: stream.index == viewModel.activeSecondarySubtitleIndex) {
                    viewModel.selectSecondarySubtitleTrack(id: stream.index)
                }
            }
            return rows
        case .speed:
            return PlayerViewModel.speedOptions.indices.map { idx in
                PickerRow(label: TransportBar.speedLabel(for: idx),
                          isActive: idx == viewModel.activeSpeedIndex) {
                    viewModel.selectSpeed(index: idx)
                }
            }
        case .picture:
            return PlaybackPreferences.PictureMode.allCases.map { mode in
                PickerRow(label: String(localized: String.LocalizationValue(mode.titleKey)),
                          isActive: mode == viewModel.pictureMode) {
                    viewModel.selectPictureMode(mode)
                }
            }
        case .episodes:
            return viewModel.seasonEpisodes.enumerated().map { idx, ep in
                PickerRow(label: ep.name, isActive: ep.id == viewModel.item.id, imageURL: episodeImageURL(ep)) {
                    Task { await viewModel.selectEpisode(at: idx) }
                }
            }
        case .chapters:
            return viewModel.chapters.enumerated().map { idx, chapter in
                PickerRow(label: chapter.name ?? "Chapter \(idx + 1)", isActive: false, chapterIndex: idx) {
                    viewModel.selectChapter(at: idx)
                }
            }
        }
    }
}

/// Lazily loads a chapter thumbnail (async CGImage from the session FrameExtractor) for a picker row.
private struct ChapterThumb: View {
    let index: Int
    let load: (Int) async -> CGImage?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1.0).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.1)
            }
        }
        .task(id: index) { image = await load(index) }
    }
}
#endif
