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
    /// Index of the currently-applied SECONDARY subtitle stream, or nil
    /// when no companion line is shown. Drives the pinned-header row and
    /// the active mark in the secondary-mode list.
    let activeSecondarySubtitleIndex: Int?
    /// Streams eligible as the secondary line (text codecs, excluding the
    /// primary). Mirrors `viewModel.secondarySubtitleCandidates`.
    let secondarySubtitleCandidates: [MediaStream]
    /// When true, the subtitle button is shown even with zero subtitle
    /// streams so the "Search online..." download entry stays reachable.
    /// Mirrors `viewModel.supportsSubtitleSearch`.
    let supportsSubtitleSearch: Bool
    let activeSpeedIndex: Int
    let controlsFocus: PlayerViewModel.ControlsFocus
    let trackDropdown: PlayerViewModel.TrackDropdown
    /// When true, a Skip Intro button sits at the leftmost slot of the
    /// transport button row. The floating glass version is suppressed
    /// in that case (see PlayerOverlayView).
    let showSkipIntroButton: Bool
    /// Episodes from the current item's season. Empty for movies and
    /// single-episode series; the episode-picker button is suppressed
    /// whenever count <= 1.
    let seasonEpisodes: [JellyfinItem]
    /// ID of the episode currently playing, used to mark the active
    /// row in the dropdown and to compose the button label.
    let activeEpisodeID: String?
    /// Resolves the thumbnail URL for an episode row. Closure rather
    /// than a hard dependency on JellyfinImageService so the SwiftUI
    /// view stays unaware of the service layer.
    let episodeImageURL: (JellyfinItem) -> URL?
    /// Source-container chapters (already sorted by start). Empty
    /// when the file ships no chapters; the button is suppressed
    /// whenever count <= 1.
    let chapters: [ChapterInfo]
    /// Total runtime in seconds, used to position the chapter ticks
    /// along the progress bar.
    let durationSeconds: Double
    /// Resolves a chapter's thumbnail as a decoded image (via the session
    /// FrameExtractor). Async + nil-returning. Closure rather than a hard
    /// dependency so the SwiftUI view stays unaware of the engine/extractor.
    let chapterThumbnail: @Sendable (Int) async -> CGImage?
    /// Currently-applied picture-fill mode. Mirrors
    /// `viewModel.pictureMode` and drives the picture button's label.
    let pictureMode: PlaybackPreferences.PictureMode
    /// Whether to surface the "Stats for Nerds" info chip after the
    /// picture button. Off by default in `PlaybackPreferences`; the
    /// chip toggles a side-panel overlay rather than opening a
    /// dropdown, so it's a no-dropdown trackButton.
    let showsInfoButton: Bool
    /// Whether the stats side-panel is currently shown. Used to give
    /// the info chip a "pressed" look so the user can tell at a glance
    /// that the overlay is mounted (toggling it off is just pressing
    /// the chip again).
    let isStatsOverlayOpen: Bool
    /// Frame-extractor preview image for the current scrub position.
    /// Nil falls the scrub display back to the time-only label.
    let previewImage: CGImage?

    var body: some View {
        VStack(spacing: 10) {
            // Scrub preview: frame-extractor card tracking the playhead
            // when an image is available, time-only otherwise.
            if isScrubbing {
                scrubPreviewArea
            }

            // Track buttons with dropdown
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

                // Chapter button: hidden on series episodes because the
                // chapter data on episodic content is usually auto-
                // generated noise (intro / credits markers, sometimes
                // a "Scene 1" stub) without real navigation value. The
                // episode picker is the primary affordance for series;
                // the chapter picker is reserved for movies and one-
                // shots where chapter metadata is typically meaningful.
                // We use `seasonEpisodes.count > 1` as the proxy for
                // "this is a series episode" since that's already wired
                // through to the transport bar.
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
                    // Speed keeps its label only while it deviates from
                    // 1x; at normal speed it collapses to the gauge icon
                    // like the other transient buttons.
                    persistsLabel: !TransportBar.isDefaultSpeed(activeSpeedIndex),
                    dropdown: speedDropdownItems,
                    isOpen: isSpeedDropdownOpen
                )

                trackButton(
                    label: pictureButtonLabel,
                    icon: pictureButtonIcon,
                    isFocused: controlsFocus == .pictureButton,
                    // The picture icon already swaps between the 16:9 and
                    // fill glyphs, so the mode reads from the icon alone;
                    // no need to keep the label pinned.
                    persistsLabel: false,
                    dropdown: pictureDropdownItems,
                    isOpen: isPictureDropdownOpen
                )

                if showsInfoButton {
                    // Info chip — toggles the stats-for-nerds side
                    // panel rather than opening a dropdown. The chip
                    // looks "pressed" while the overlay is mounted so
                    // the user can read the state visually instead of
                    // remembering which click did what.
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
            // Force every focus-driven change in the track-button row onto
            // one shared smooth curve, mirroring the detail-view
            // CollapsingActionRowModifier. Riding the same transaction as
            // the controlsFocus mutation makes the icon-only label reveal,
            // the pill scale, and the sibling reflow all interpolate
            // together. An .animation(value:) here lagged a frame in the
            // detail views (only the immediate neighbor glided), which is
            // why we use a transaction instead.
            .transaction { txn in
                txn.animation = .smooth(duration: 0.32)
            }

            // Progress bar
            progressBar

            // Time labels
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
        // Match the track-button row's smooth curve so focus moving onto or
        // off the progress bar interpolates with the same feel as the pills.
        .animation(.smooth(duration: 0.32), value: controlsFocus)
        .animation(.smooth(duration: 0.32), value: trackDropdown)
    }

    // MARK: - Scrub Preview

    private static let scrubCardWidth: CGFloat = 320

    @ViewBuilder
    private var scrubPreviewArea: some View {
        if let previewImage {
            GeometryReader { geo in
                let width = geo.size.width
                let half = Self.scrubCardWidth / 2
                let knobX = max(0, min(width, width * CGFloat(progress)))
                let clampedX = max(half, min(width - half, knobX))
                scrubPreviewCard(image: previewImage)
                    .position(x: clampedX, y: scrubCardHeight / 2)
            }
            .frame(height: scrubCardHeight)
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

    /// 16:9 image (180 pt tall at 320 pt wide) plus the time label below.
    private var scrubCardHeight: CGFloat { Self.scrubCardWidth * 9 / 16 + 34 }

    private func scrubPreviewCard(image: CGImage) -> some View {
        VStack(spacing: 6) {
            Image(decorative: image, scale: 1.0)
                .resizable()
                .aspectRatio(16.0 / 9.0, contentMode: .fill)
                .frame(width: Self.scrubCardWidth, height: Self.scrubCardWidth * 9 / 16)
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

    /// Currently-active chapter index, the last chapter whose start
    /// is at or before the current playback progress. Nil only when
    /// the chapter list is empty (the button is hidden in that case
    /// anyway).
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

    /// Button label = current chapter name, falling back to "Chapter
    /// N / Total" when the chapter has no name set.
    private var chapterButtonLabel: String {
        guard let i = activeChapterIndex else {
            return String(localized: "player.chapters", defaultValue: "Chapters")
        }
        if let name = chapters[i].name, !name.isEmpty {
            return name
        }
        return "\(i + 1) / \(chapters.count)"
    }

    /// "S1E5" / "S2E12" if the current episode has both numbers, falls
    /// back to just the index, then to a generic label so the button
    /// always has something to render.
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

    /// "12:34  Opening" / "12:34  Chapter 3" depending on whether the
    /// chapter has a name. Timestamp first so all rows stay vertically
    /// aligned in the dropdown.
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

    /// "1×" / "1.5×" / "0.75×", fixed-style, not localized (the × glyph
    /// and arabic digits are universal in the native tvOS player too).
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

    /// Whether the active speed index is the default 1x rate. The speed
    /// button only pins its label when the rate deviates from this, so
    /// at normal speed it collapses to the gauge icon.
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
        let candidates = secondarySubtitleCandidates
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
        items += candidates.enumerated().map { idx, stream in
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
    /// Episode rows carry a 16:9 thumbnail and the episode title, so
    /// they need a taller row to read at TV viewing distance. The
    /// image renders at 120×68 with 8pt vertical breathing room → 84pt
    /// total. Audio/subtitle/speed dropdowns stay on the compact 56pt
    /// row.
    private static let episodeRowHeight: CGFloat = 84
    private static let dropdownMaxVisible: Int = 6

    private func trackButton(label: String, icon: String, isFocused: Bool, persistsLabel: Bool, dropdown: [DropdownItem], isOpen: Bool) -> some View {
        VStack(spacing: 6) {
            // Dropdown menu (opens upward, scrollable if many items)
            if isOpen {
                let hasImages = dropdown.contains(where: { $0.image != nil })
                let rowHeight = hasImages ? Self.episodeRowHeight : Self.dropdownItemHeight
                // Pinned footer rows (the subtitle "Search online..." row)
                // render below the scroll area so they stay visible no
                // matter how long the list is. Indices are preserved so the
                // host-driven highlight math is unaffected.
                let indexed = Array(dropdown.enumerated())
                let headerIndexed = indexed.filter { $0.element.isPinnedHeader }
                let scrollIndexed = indexed.filter { !$0.element.isPinnedFooter && !$0.element.isPinnedHeader }
                let pinnedIndexed = indexed.filter { $0.element.isPinnedFooter }
                let visibleCount = min(scrollIndexed.count, Self.dropdownMaxVisible)
                let height = CGFloat(visibleCount) * rowHeight

                VStack(spacing: 0) {
                    // Fixed header (e.g. "Secondary: ..."), always visible.
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
                            // The first render needs an explicit scroll,
                            // .onChange only fires when the highlighted
                            // index *changes*, not for the value the
                            // dropdown was opened at. Without this the
                            // scrollview anchors at index 0 and the
                            // active row is offscreen until the user
                            // moves the highlight one step.
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

                    // Fixed footer (e.g. "Search online..."), always visible.
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
                // Image dropdowns (episodes / chapters w/ thumbnails)
                // get a tight cap so long titles wrap inside the row
                // instead of stretching the column wide enough to
                // squeeze the rest of the transport buttons. Text-only
                // dropdowns (audio / subs / speed / picture) have
                // shorter content by nature, give them generous
                // headroom so names like "Deutsch · Dolby TrueHD 7.1"
                // don't truncate to "Deutsch · Dol…".
                .frame(
                    minWidth: hasImages ? 480 : 0,
                    maxWidth: hasImages ? 720 : 800
                )
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .fixedSize(horizontal: true, vertical: false)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Button: icon always visible, label collapses unless the
            // button is focused or `persistsLabel` keeps it pinned
            // (active audio / subtitle / episode, non-1x speed). Mirrors
            // the detail-view GlassActionButton icon-only collapse.
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
                // Unplayed track, stays white so the contrast against
                // the played portion reads clearly regardless of which
                // accent color the user picked.
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(height: trackHeight)

                // Chapter markers, narrow vertical ticks at each
                // chapter's start position. Drawn on top of the
                // unplayed track and below the played portion so they
                // appear muted-white in the unplayed section and
                // melt into the tint behind the playhead. Skip the
                // very first chapter (always at 0:00, would visually
                // collide with the left edge).
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

                // Played portion + scrub knob both follow the active
                // tint so the progress bar visually agrees with the
                // accent color the rest of the focused UI uses.
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

/// A transport-bar track button's icon + collapsible text label.
///
/// The SF Symbol stays visible at all times; the text reveals with a
/// width animation when `showsLabel` is true (the button is focused, or
/// the caller pinned the label for active-state buttons like audio /
/// subtitle / episode and non-1x speed). This mirrors the detail-view
/// `GlassActionButton` icon-only collapse, but is driven by an explicit
/// `isFocused` flag instead of `@Environment(\.isFocused)` because the
/// transport bar's focus lives in `PlayerViewModel.controlsFocus`, not
/// the SwiftUI focus system.
private struct TransportTrackLabel: View {
    let label: String
    let icon: String
    let showsLabel: Bool
    let isFocused: Bool

    /// Measured intrinsic width of the trailing text (its leading gap
    /// baked in). The visible copy animates its frame between 0 and this
    /// so the reveal interpolates the real layout footprint.
    @State private var labelWidth: CGFloat = 0

    private var labelFrameWidth: CGFloat? {
        guard showsLabel else { return 0 }
        return labelWidth > 0 ? labelWidth : nil
    }

    /// The collapsible trailing text, with the gap to the leading glyph
    /// baked into the measured width.
    private var labelInner: some View {
        Text(label)
            .font(.callout)
            // Single-line guarantee: when an open dropdown column pushes
            // layout pressure across the row, this keeps labels like
            // "Original" / "Deutsch" from breaking mid-word.
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
        // Icon-only pills get tighter padding so they read as compact
        // squares rather than wide empty capsules.
        .padding(.horizontal, showsLabel ? 16 : 12)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: false)
        // Hidden full-size copy measures the label's intrinsic width
        // without contributing to layout (a background never stretches
        // its primary), so it reports the true width even while the
        // visible copy is clipped to zero.
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
        // Lift the focused pill off the video with the same depth cue the
        // detail-view GlassActionButton uses, so the highlight reads as
        // "raised" rather than just tinted.
        .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 10, y: 5)
        // Per-button focus animation, matching the detail-view button
        // style. The enclosing row also forces this curve via a
        // transaction (see the track-button HStack) so the focused pill
        // and every sibling interpolate together instead of the neighbor
        // gliding while distant pills snap.
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
    /// Optional thumbnail source. Episode picker uses `.url`; chapter
    /// picker uses `.chapterThumbnail`. Other dropdowns leave it nil.
    var image: DropdownImage? = nil
    /// Optional trailing affordance caption (e.g. "Hold to delete" on
    /// external subtitle rows). nil for rows without a secondary action.
    var hint: String? = nil
    /// Pins this row as a fixed footer below the scrollable list, so it
    /// stays visible no matter how long the list is (the subtitle
    /// dropdown's "Search online..." row).
    var isPinnedFooter: Bool = false
    /// Draws a thin separator above this row, to set it apart from the
    /// rows above (used with `isPinnedFooter`).
    var separatorAbove: Bool = false
    /// Pins this row as a fixed HEADER above the scrollable list, so it
    /// stays visible no matter how long the list is (the subtitle
    /// dropdown's "Secondary: ..." row). Mirror of `isPinnedFooter`.
    var isPinnedHeader: Bool = false
    /// Draws a thin separator below this row (used with `isPinnedHeader`).
    var separatorBelow: Bool = false
}

// MARK: - Chapter Thumbnail View

/// Loads a chapter thumbnail (the Jellyfin-rendered chapter image when the
/// server has one, otherwise a FrameExtractor still) when the row appears.
/// Shows the gray placeholder until ready. Lazy rendering means only visible
/// rows load; server images hit the shared ImageCache, extractor stills the
/// extractor's LRU, so repeats are cheap.
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
        // Glide the highlight as it steps between rows instead of snapping,
        // matching the track-button row's smooth focus feel.
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
