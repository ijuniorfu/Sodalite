import SwiftUI
import AetherEngine

/// Native tvOS-style transport bar with progress bar, time labels,
/// and track selection buttons with dropdown menus.
///
/// Layout (dropdown open):
/// ```
///                    ┌──────────────┐
///                    │ English  ✓   │
///                    │ German       │
///                    │ Japanese     │
///                    └──────────────┘
///                         [Audio ▲]  [Subs]
/// ═══════════════════●══════════════════════
/// 00:12:34                        -01:23:45
/// ```
struct TransportBar: View {
    let progress: Float
    let currentTime: String
    let remainingTime: String
    let isScrubbing: Bool
    let scrubTime: String
    let audioTracks: [TrackInfo]
    let subtitleStreams: [MediaStream]
    let activeAudioIndex: Int?
    let activeSubtitleIndex: Int?
    /// Currently-applied SECONDARY subtitle stream index, or nil when no companion line shows.
    let activeSecondarySubtitleIndex: Int?
    /// Streams eligible as the secondary line (text codecs, excluding the primary).
    let secondarySubtitleCandidates: [MediaStream]
    /// Show the subtitle button even with zero streams so "Search online..." stays reachable.
    let supportsSubtitleSearch: Bool
    let activeSpeedIndex: Int
    let controlsFocus: PlayerViewModel.ControlsFocus
    let trackDropdown: PlayerViewModel.TrackDropdown
    /// Skip Intro button at the leftmost slot; the floating glass version is suppressed then.
    let showSkipIntroButton: Bool
    /// Current season's episodes; button suppressed when count <= 1.
    let seasonEpisodes: [JellyfinItem]
    let activeEpisodeID: String?
    /// Resolves an episode row thumbnail URL; a closure so the view stays unaware of the service layer.
    let episodeImageURL: (JellyfinItem) -> URL?
    /// Source-container chapters (sorted by start); button suppressed when count <= 1.
    let chapters: [ChapterInfo]
    /// Total runtime in seconds, used to position chapter ticks on the progress bar.
    let durationSeconds: Double
    /// Resolves a chapter thumbnail via the session FrameExtractor; closure keeps the view
    /// unaware of the engine/extractor.
    let chapterThumbnail: @Sendable (Int) async -> CGImage?
    let pictureMode: PlaybackPreferences.PictureMode
    /// "Stats for Nerds" info chip (off by default); toggles a side-panel overlay, no dropdown.
    let showsInfoButton: Bool
    /// Whether the stats panel is open; gives the chip a "pressed" look so the state reads visually.
    let isStatsOverlayOpen: Bool
    /// Scrub-position preview frame; nil falls back to the time-only label.
    let previewImage: CGImage?

    var body: some View {
        VStack(spacing: 10) {
            if isScrubbing {
                scrubPreviewArea
            }

            HStack(alignment: .bottom, spacing: 16) {
                Spacer()

                if showSkipIntroButton {
                    trackButton(
                        label: String(localized: "player.skipIntro", defaultValue: "Skip Intro"),
                        icon: "forward.end.fill",
                        isFocused: controlsFocus == .skipIntroButton,
                        persistsLabel: false,
                        dropdown: [],
                        isOpen: false
                    )
                }

                if seasonEpisodes.count > 1 {
                    trackButton(
                        label: episodeButtonLabel,
                        icon: "list.bullet",
                        isFocused: controlsFocus == .episodeButton,
                        persistsLabel: true,
                        dropdown: episodeDropdownItems,
                        isOpen: isEpisodeDropdownOpen
                    )
                }

                // Chapter button hidden on series episodes (chapter data there is usually
                // auto-generated noise); `seasonEpisodes.count > 1` is the "is an episode" proxy.
                if chapters.count > 1, seasonEpisodes.count <= 1 {
                    trackButton(
                        label: chapterButtonLabel,
                        icon: "list.dash",
                        isFocused: controlsFocus == .chapterButton,
                        persistsLabel: false,
                        dropdown: chapterDropdownItems,
                        isOpen: isChapterDropdownOpen
                    )
                }

                if !audioTracks.isEmpty {
                    let activeTrack = audioTracks.first(where: { $0.id == activeAudioIndex })
                    trackButton(
                        label: activeTrack.map { TrackDisplayFormatter.shortName(for: $0) }
                            ?? String(localized: "player.audio", defaultValue: "Audio"),
                        icon: "speaker.wave.2",
                        isFocused: controlsFocus == .audioButton,
                        persistsLabel: true,
                        dropdown: audioDropdownItems,
                        isOpen: isAudioDropdownOpen
                    )
                }

                if !subtitleStreams.isEmpty || supportsSubtitleSearch {
                    let activeStream = activeSubtitleIndex.flatMap { idx in
                        subtitleStreams.first(where: { $0.index == idx })
                    }
                    trackButton(
                        label: activeStream.map { TrackDisplayFormatter.subtitleShortName(for: $0) }
                            ?? String(localized: "player.subtitles.off", defaultValue: "Off"),
                        icon: "captions.bubble",
                        isFocused: controlsFocus == .subtitleButton,
                        persistsLabel: true,
                        dropdown: {
                            if case .secondarySubtitle = trackDropdown { return secondarySubtitleDropdownItems }
                            return subtitleDropdownItems
                        }(),
                        isOpen: isSubtitleDropdownOpen || isSecondarySubtitleDropdownOpen
                    )
                }

                trackButton(
                    label: TransportBar.speedLabel(for: activeSpeedIndex),
                    icon: "gauge.with.needle",
                    isFocused: controlsFocus == .speedButton,
                    // Label persists only off 1x; at normal speed it collapses to the gauge icon.
                    persistsLabel: !TransportBar.isDefaultSpeed(activeSpeedIndex),
                    dropdown: speedDropdownItems,
                    isOpen: isSpeedDropdownOpen
                )

                trackButton(
                    label: pictureButtonLabel,
                    icon: pictureButtonIcon,
                    isFocused: controlsFocus == .pictureButton,
                    // Icon already swaps 16:9 vs fill glyph, so the mode reads without a pinned label.
                    persistsLabel: false,
                    dropdown: pictureDropdownItems,
                    isOpen: isPictureDropdownOpen
                )

                if showsInfoButton {
                    // Info chip toggles the stats side panel (no dropdown); looks pressed while open.
                    trackButton(
                        label: String(localized: "player.stats", defaultValue: "Stats"),
                        icon: "info.circle",
                        isFocused: controlsFocus == .infoButton || isStatsOverlayOpen,
                        persistsLabel: false,
                        dropdown: [],
                        isOpen: false
                    )
                }
            }
            .padding(.bottom, 4)
            // Transaction (not .animation(value:), which lagged a frame so only the immediate
            // neighbor glided) puts label reveal, pill scale, and sibling reflow on one curve.
            .transaction { txn in
                txn.animation = .smooth(duration: 0.32)
            }

            progressBar

            HStack {
                Text(currentTime)
                    .font(.callout)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()

                Text(remainingTime)
                    .font(.callout)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 60)
        .animation(.easeInOut(duration: 0.2), value: isScrubbing)
        .animation(.smooth(duration: 0.32), value: controlsFocus)
        .animation(.smooth(duration: 0.32), value: trackDropdown)
    }

    // MARK: - Scrub Preview

    private static let scrubCardWidth: CGFloat = 320

    @ViewBuilder
    private var scrubPreviewArea: some View {
        if let previewImage {
            let imageHeight = Self.previewImageHeight(for: previewImage)
            let cardHeight = imageHeight + 34
            GeometryReader { geo in
                let width = geo.size.width
                let half = Self.scrubCardWidth / 2
                let knobX = max(0, min(width, width * CGFloat(progress)))
                let clampedX = max(half, min(width - half, knobX))
                scrubPreviewCard(image: previewImage, imageHeight: imageHeight)
                    .position(x: clampedX, y: cardHeight / 2)
            }
            .frame(height: cardHeight)
            .padding(.bottom, 12)
            .transition(.opacity)
        } else {
            Text(scrubTime)
                .font(.system(size: 56, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .transition(.opacity)
                .padding(.bottom, 16)
        }
    }

    /// Preview height at the fixed card width from the frame's own (SAR-corrected) aspect, so a
    /// 4:3 DVD stays 4:3 instead of being stretched to 16:9. Clamped; degenerate frames use 16:9.
    static func previewImageHeight(for image: CGImage) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return scrubCardWidth * 9 / 16 }
        let h = scrubCardWidth * CGFloat(image.height) / CGFloat(image.width)
        return min(max(h, scrubCardWidth * 9 / 21), scrubCardWidth)
    }

    private func scrubPreviewCard(image: CGImage, imageHeight: CGFloat) -> some View {
        VStack(spacing: 6) {
            Image(decorative: image, scale: 1.0)
                .resizable()
                .frame(width: Self.scrubCardWidth, height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)

            Text(scrubTime)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }

    // MARK: - Dropdown State

    private var isAudioDropdownOpen: Bool {
        if case .audio = trackDropdown { return true }
        return false
    }

    private var isSubtitleDropdownOpen: Bool {
        if case .subtitle = trackDropdown { return true }
        return false
    }

    private var isSecondarySubtitleDropdownOpen: Bool {
        if case .secondarySubtitle = trackDropdown { return true }
        return false
    }

    private var isSpeedDropdownOpen: Bool {
        if case .speed = trackDropdown { return true }
        return false
    }

    private var isEpisodeDropdownOpen: Bool {
        if case .episode = trackDropdown { return true }
        return false
    }

    private var isChapterDropdownOpen: Bool {
        if case .chapter = trackDropdown { return true }
        return false
    }

    private var isPictureDropdownOpen: Bool {
        if case .picture = trackDropdown { return true }
        return false
    }

    private var pictureButtonIcon: String {
        switch pictureMode {
        case .original: return "rectangle.ratio.16.to.9"
        case .fill:     return "rectangle.expand.vertical"
        }
    }

    private var pictureButtonLabel: String {
        String(localized: String.LocalizationValue(pictureMode.titleKey))
    }

    private var pictureDropdownItems: [DropdownItem] {
        guard case .picture(let highlighted) = trackDropdown else { return [] }
        return PlaybackPreferences.PictureMode.allCases.enumerated().map { idx, mode in
            DropdownItem(
                title: String(localized: String.LocalizationValue(mode.titleKey)),
                isActive: mode == pictureMode,
                isHighlighted: idx == highlighted
            )
        }
    }

    /// Active chapter: last chapter starting at or before current progress; nil only when empty.
    private var activeChapterIndex: Int? {
        guard !chapters.isEmpty else { return nil }
        let nowSeconds = Double(progress) * max(durationSeconds, 0)
        var idx = 0
        for (i, chapter) in chapters.enumerated() {
            if chapter.startSeconds <= nowSeconds + 0.001 {
                idx = i
            } else {
                break
            }
        }
        return idx
    }

    /// Current chapter name, falling back to "N / Total" when unnamed.
    private var chapterButtonLabel: String {
        guard let i = activeChapterIndex else {
            return String(localized: "player.chapters", defaultValue: "Chapters")
        }
        if let name = chapters[i].name, !name.isEmpty {
            return name
        }
        return "\(i + 1) / \(chapters.count)"
    }

    /// "S1E5" when both numbers exist, else a generic label.
    private var episodeButtonLabel: String {
        let active = seasonEpisodes.first(where: { $0.id == activeEpisodeID })
        if let active {
            var parts: [String] = []
            if let s = active.parentIndexNumber { parts.append("S\(s)") }
            if let e = active.indexNumber { parts.append("E\(e)") }
            if !parts.isEmpty { return parts.joined() }
        }
        return String(localized: "player.episodes", defaultValue: "Episodes")
    }

    private var episodeDropdownItems: [DropdownItem] {
        guard case .episode(let highlighted) = trackDropdown else { return [] }
        return seasonEpisodes.enumerated().map { idx, episode in
            DropdownItem(
                title: episodeRowTitle(for: episode),
                isActive: episode.id == activeEpisodeID,
                isHighlighted: idx == highlighted,
                image: episodeImageURL(episode).map(DropdownImage.url)
            )
        }
    }

    private var chapterDropdownItems: [DropdownItem] {
        guard case .chapter(let highlighted) = trackDropdown else { return [] }
        let active = activeChapterIndex
        return chapters.enumerated().map { idx, chapter in
            DropdownItem(
                title: chapterRowTitle(for: chapter, index: idx),
                isActive: idx == active,
                isHighlighted: idx == highlighted,
                image: .chapterThumbnail(idx)
            )
        }
    }

    /// "12:34  Name" (timestamp first so dropdown rows stay aligned), falling back to "Chapter N".
    private func chapterRowTitle(for chapter: ChapterInfo, index: Int) -> String {
        let stamp = TransportBar.formatChapterTime(chapter.startSeconds)
        let name = chapter.name.flatMap { $0.isEmpty ? nil : $0 }
            ?? String(localized: "player.chapter.fallback", defaultValue: "Chapter \(index + 1)")
        return "\(stamp)  \(name)"
    }

    private static func formatChapterTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func episodeRowTitle(for episode: JellyfinItem) -> String {
        var prefix = ""
        if let e = episode.indexNumber {
            prefix = "E\(e) · "
        }
        return prefix + episode.name
    }

    /// "1×" / "1.5×", deliberately not localized (× glyph + arabic digits are universal).
    static func speedLabel(for index: Int) -> String {
        let rate = PlayerViewModel.speedOptions[
            max(0, min(PlayerViewModel.speedOptions.count - 1, index))
        ]
        if rate == rate.rounded() {
            return "\(Int(rate))×"
        }
        // Strip trailing zeros (0.50 → 0.5)
        let s = String(format: "%.2f", rate)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        return "\(s)×"
    }

    static func isDefaultSpeed(_ index: Int) -> Bool {
        let rate = PlayerViewModel.speedOptions[
            max(0, min(PlayerViewModel.speedOptions.count - 1, index))
        ]
        return rate == 1.0
    }

    private var audioDropdownItems: [DropdownItem] {
        guard case .audio(let highlighted) = trackDropdown else { return [] }
        return audioTracks.enumerated().map { idx, track in
            DropdownItem(
                title: TrackDisplayFormatter.audioDisplayName(for: track),
                isActive: track.id == activeAudioIndex,
                isHighlighted: idx == highlighted
            )
        }
    }

    private var subtitleDropdownItems: [DropdownItem] {
        guard case .subtitle(let highlighted) = trackDropdown else { return [] }
        let secondaryName: String = {
            guard let idx = activeSecondarySubtitleIndex,
                  let stream = subtitleStreams.first(where: { $0.index == idx }) else {
                return String(localized: "player.subtitle.secondary.none", defaultValue: "Secondary: Off")
            }
            return String(format: String(localized: "player.subtitle.secondary.value", defaultValue: "Secondary: %@"),
                          TrackDisplayFormatter.subtitleStreamDisplayName(for: stream))
        }()
        var items: [DropdownItem] = [
            DropdownItem(
                title: secondaryName,
                isActive: false,
                isHighlighted: highlighted == 0,
                isPinnedHeader: true,
                separatorBelow: true
            ),
            DropdownItem(
                title: String(localized: "player.subtitles.off", defaultValue: "Off"),
                isActive: activeSubtitleIndex == nil,
                isHighlighted: highlighted == 1
            )
        ]
        items += subtitleStreams.enumerated().map { idx, stream in
            DropdownItem(
                title: TrackDisplayFormatter.subtitleStreamDisplayName(for: stream),
                isActive: stream.index == activeSubtitleIndex,
                isHighlighted: idx + 2 == highlighted,
                hint: stream.isExternal == true
                    ? String(localized: "player.subtitle.delete.hint", defaultValue: "Hold to delete")
                    : nil
            )
        }
        items.append(
            DropdownItem(
                title: String(localized: "player.subtitle.searchOnline", defaultValue: "Search online..."),
                isActive: false,
                isHighlighted: highlighted == subtitleStreams.count + 2,
                isPinnedFooter: true,
                separatorAbove: true
            )
        )
        return items
    }

    private var secondarySubtitleDropdownItems: [DropdownItem] {
        guard case .secondarySubtitle(let highlighted) = trackDropdown else { return [] }
        var items: [DropdownItem] = [
            DropdownItem(
                title: String(localized: "player.subtitle.secondary.back", defaultValue: "Back"),
                isActive: false,
                isHighlighted: highlighted == 0,
                isPinnedHeader: true,
                separatorBelow: true
            ),
            DropdownItem(
                title: String(localized: "player.subtitles.off", defaultValue: "Off"),
                isActive: activeSecondarySubtitleIndex == nil,
                isHighlighted: highlighted == 1
            )
        ]
        items += secondarySubtitleCandidates.enumerated().map { idx, stream in
            DropdownItem(
                title: TrackDisplayFormatter.subtitleStreamDisplayName(for: stream),
                isActive: stream.index == activeSecondarySubtitleIndex,
                isHighlighted: idx + 2 == highlighted
            )
        }
        return items
    }

    private var speedDropdownItems: [DropdownItem] {
        guard case .speed(let highlighted) = trackDropdown else { return [] }
        return PlayerViewModel.speedOptions.enumerated().map { idx, _ in
            DropdownItem(
                title: TransportBar.speedLabel(for: idx),
                isActive: idx == activeSpeedIndex,
                isHighlighted: idx == highlighted
            )
        }
    }

    // MARK: - Track Button + Dropdown

    private static let dropdownItemHeight: CGFloat = 56
    /// Taller row for thumbnail dropdowns (120×68 image + 8pt breathing room); text-only stays 56.
    private static let episodeRowHeight: CGFloat = 84
    private static let dropdownMaxVisible: Int = 6

    private func trackButton(label: String, icon: String, isFocused: Bool, persistsLabel: Bool, dropdown: [DropdownItem], isOpen: Bool) -> some View {
        VStack(spacing: 6) {
            if isOpen {
                let hasImages = dropdown.contains(where: { $0.image != nil })
                let rowHeight = hasImages ? Self.episodeRowHeight : Self.dropdownItemHeight
                // Pinned header/footer rows render outside the scroll area so they stay visible;
                // original indices are preserved so the host-driven highlight math is unaffected.
                let indexed = Array(dropdown.enumerated())
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

            TransportTrackLabel(
                label: label,
                icon: icon,
                showsLabel: persistsLabel || isFocused,
                isFocused: isFocused
            )
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knobX = max(0, min(width, width * CGFloat(progress)))
            let active = isScrubbing || controlsFocus == .progressBar
            let trackHeight: CGFloat = active ? 10 : 6
            let knobSize: CGFloat = active ? 22 : 14

            ZStack(alignment: .leading) {
                // Unplayed track stays white for contrast regardless of the user's accent color.
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(height: trackHeight)

                // Chapter ticks, drawn above the unplayed track and below the played portion so
                // they melt into the tint behind the playhead. Skip the first (at 0:00, edge collision).
                if chapters.count > 1, durationSeconds > 0 {
                    ForEach(chapters.dropFirst().indices, id: \.self) { i in
                        let frac = chapters[i].startSeconds / durationSeconds
                        if frac > 0, frac < 1 {
                            Capsule()
                                .fill(.white.opacity(0.55))
                                .frame(width: 2, height: trackHeight + 4)
                                .offset(x: width * CGFloat(frac) - 1)
                        }
                    }
                }

                // Played portion + knob follow the active tint to match the focused UI accent.
                Capsule()
                    .fill(.tint)
                    .frame(width: knobX, height: trackHeight)

                Circle()
                    .fill(.tint)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .offset(x: knobX - knobSize / 2)
            }
            .animation(.easeInOut(duration: 0.2), value: active)
        }
        .frame(height: 22)
    }
}

// MARK: - Transport Track Button Label

/// A track button's always-visible icon + width-animated text label (revealed when `showsLabel`).
/// Driven by an explicit `isFocused` flag, not `@Environment(\.isFocused)`, because transport-bar
/// focus lives in `PlayerViewModel.controlsFocus`, not the SwiftUI focus system.
private struct TransportTrackLabel: View {
    let label: String
    let icon: String
    let showsLabel: Bool
    let isFocused: Bool

    /// Measured intrinsic text width (leading gap baked in); the visible copy animates 0→this.
    @State private var labelWidth: CGFloat = 0

    private var labelFrameWidth: CGFloat? {
        guard showsLabel else { return 0 }
        return labelWidth > 0 ? labelWidth : nil
    }

    /// Collapsible trailing text, with the gap to the leading glyph baked into the measured width.
    private var labelInner: some View {
        Text(label)
            .font(.callout)
            // Single-line guarantee so an open dropdown's layout pressure can't break labels mid-word.
            .lineLimit(1)
            .padding(.leading, 8)
            .fixedSize()
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.callout)

            labelInner
                .frame(width: labelFrameWidth, alignment: .leading)
                .opacity(showsLabel ? 1 : 0)
                .clipped()
        }
        .foregroundStyle(isFocused ? .white : .white.opacity(0.6))
        // Tighter padding for icon-only pills so they read as compact squares, not empty capsules.
        .padding(.horizontal, showsLabel ? 16 : 12)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: false)
        // Hidden full-size copy in a background (never stretches its primary) measures the true
        // intrinsic width even while the visible copy is clipped to zero.
        .background(alignment: .leading) {
            labelInner
                .hidden()
                .background(GeometryReader { geo in
                    Color.clear.preference(
                        key: TransportLabelWidthKey.self, value: geo.size.width
                    )
                })
        }
        .onPreferenceChange(TransportLabelWidthKey.self) { labelWidth = $0 }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? .white.opacity(0.2) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(isFocused ? 1 : 0)
        )
        .scaleEffect(isFocused ? 1.08 : 1.0)
        // Depth cue so the focused pill reads as raised, not just tinted.
        .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 10, y: 5)
        // Per-button focus animation; the enclosing row also forces this curve via a transaction
        // so every sibling interpolates together instead of distant pills snapping.
        .animation(.smooth(duration: 0.32), value: isFocused)
    }
}

private struct TransportLabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Dropdown Item

private enum DropdownImage {
    case url(URL)                 // episode picker: Jellyfin image
    case chapterThumbnail(Int)    // chapter picker: server chapter image, else FrameExtractor still
}

private struct DropdownItem {
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

// MARK: - Dropdown Row

private extension TransportBar {
    @ViewBuilder
    func dropdownRow(item: DropdownItem, hasImages: Bool, rowHeight: CGFloat) -> some View {
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
                        ChapterThumbnailView(index: index, load: chapterThumbnail)
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

// MARK: - Title Overlay

struct PlayerTitleOverlay: View {
    let item: JellyfinItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let seriesName = item.seriesName {
                Text(seriesName)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                let episodeLabel = episodeDescription
                if !episodeLabel.isEmpty {
                    Text(episodeLabel)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            } else {
                Text(item.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let year = item.productionYear {
                    Text(String(year))
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 60)
    }

    private var episodeDescription: String {
        var parts: [String] = []
        if let season = item.parentIndexNumber {
            parts.append("S\(season)")
        }
        if let episode = item.indexNumber {
            parts.append("E\(episode)")
        }
        let prefix = parts.joined(separator: "")
        if prefix.isEmpty {
            return item.name
        }
        return "\(prefix) \(item.name)"
    }
}
