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
    /// ID of the episode currently playing — used to mark the active
    /// row in the dropdown and to compose the button label.
    let activeEpisodeID: String?
    /// Resolves the thumbnail URL for an episode row. Closure rather
    /// than a hard dependency on JellyfinImageService so the SwiftUI
    /// view stays unaware of the service layer.
    let episodeImageURL: (JellyfinItem) -> URL?

    var body: some View {
        VStack(spacing: 10) {
            // Scrub time preview
            if isScrubbing {
                Text(scrubTime)
                    .font(.system(size: 56, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .transition(.opacity)
                    .padding(.bottom, 16)
            }

            // Track buttons with dropdown
            HStack(alignment: .bottom, spacing: 16) {
                Spacer()

                if showSkipIntroButton {
                    trackButton(
                        label: String(localized: "player.skipIntro", defaultValue: "Skip Intro"),
                        icon: "forward.end.fill",
                        isFocused: controlsFocus == .skipIntroButton,
                        dropdown: [],
                        isOpen: false
                    )
                }

                if seasonEpisodes.count > 1 {
                    trackButton(
                        label: episodeButtonLabel,
                        icon: "list.bullet",
                        isFocused: controlsFocus == .episodeButton,
                        dropdown: episodeDropdownItems,
                        isOpen: isEpisodeDropdownOpen
                    )
                }

                if !audioTracks.isEmpty {
                    let activeTrack = audioTracks.first(where: { $0.id == activeAudioIndex })
                    trackButton(
                        label: activeTrack.map { TrackDisplayFormatter.shortName(for: $0) }
                            ?? String(localized: "player.audio", defaultValue: "Audio"),
                        icon: "speaker.wave.2",
                        isFocused: controlsFocus == .audioButton,
                        dropdown: audioDropdownItems,
                        isOpen: isAudioDropdownOpen
                    )
                }

                if !subtitleStreams.isEmpty {
                    let activeStream = activeSubtitleIndex.flatMap { idx in
                        subtitleStreams.first(where: { $0.index == idx })
                    }
                    trackButton(
                        label: activeStream.map { TrackDisplayFormatter.subtitleShortName(for: $0) }
                            ?? String(localized: "player.subtitles.off", defaultValue: "Off"),
                        icon: "captions.bubble",
                        isFocused: controlsFocus == .subtitleButton,
                        dropdown: subtitleDropdownItems,
                        isOpen: isSubtitleDropdownOpen
                    )
                }

                trackButton(
                    label: TransportBar.speedLabel(for: activeSpeedIndex),
                    icon: "gauge.with.needle",
                    isFocused: controlsFocus == .speedButton,
                    dropdown: speedDropdownItems,
                    isOpen: isSpeedDropdownOpen
                )
            }
            .padding(.bottom, 4)

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
        .animation(.easeInOut(duration: 0.15), value: controlsFocus)
        .animation(.easeInOut(duration: 0.15), value: trackDropdown)
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

    private var isSpeedDropdownOpen: Bool {
        if case .speed = trackDropdown { return true }
        return false
    }

    private var isEpisodeDropdownOpen: Bool {
        if case .episode = trackDropdown { return true }
        return false
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
                imageURL: episodeImageURL(episode)
            )
        }
    }

    private func episodeRowTitle(for episode: JellyfinItem) -> String {
        var prefix = ""
        if let e = episode.indexNumber {
            prefix = "E\(e) · "
        }
        return prefix + episode.name
    }

    /// "1×" / "1.5×" / "0.75×" — fixed-style, not localized (the × glyph
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
        var items: [DropdownItem] = [
            DropdownItem(
                title: String(localized: "player.subtitles.off", defaultValue: "Off"),
                isActive: activeSubtitleIndex == nil,
                isHighlighted: highlighted == 0
            )
        ]
        items += subtitleStreams.enumerated().map { idx, stream in
            DropdownItem(
                title: TrackDisplayFormatter.subtitleStreamDisplayName(for: stream),
                isActive: stream.index == activeSubtitleIndex,
                isHighlighted: idx + 1 == highlighted
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

    private func trackButton(label: String, icon: String, isFocused: Bool, dropdown: [DropdownItem], isOpen: Bool) -> some View {
        VStack(spacing: 6) {
            // Dropdown menu (opens upward, scrollable if many items)
            if isOpen {
                let hasImages = dropdown.contains(where: { $0.imageURL != nil })
                let rowHeight = hasImages ? Self.episodeRowHeight : Self.dropdownItemHeight
                let itemCount = dropdown.count
                let visibleCount = min(itemCount, Self.dropdownMaxVisible)
                let height = CGFloat(visibleCount) * rowHeight

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(dropdown.enumerated()), id: \.offset) { idx, item in
                                dropdownRow(item: item, hasImages: hasImages, rowHeight: rowHeight)
                                    .id(idx)
                            }
                        }
                    }
                    .onChange(of: dropdown.firstIndex(where: { $0.isHighlighted })) { _, highlighted in
                        if let highlighted {
                            withAnimation { proxy.scrollTo(highlighted, anchor: .center) }
                        }
                    }
                }
                .frame(height: height)
                .frame(minWidth: hasImages ? 480 : 0)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .fixedSize(horizontal: true, vertical: false)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Button label
            Label(label, systemImage: icon)
                .font(.callout)
                .foregroundStyle(isFocused ? .white : .white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isFocused ? .white.opacity(0.2) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.tint, lineWidth: 3)
                        .opacity(isFocused ? 1 : 0)
                )
                .scaleEffect(isFocused ? 1.05 : 1.0)
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
                // Unplayed track — stays white so the contrast against
                // the played portion reads clearly regardless of which
                // accent color the user picked.
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(height: trackHeight)

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

// MARK: - Dropdown Item

private struct DropdownItem {
    let title: String
    let isActive: Bool
    let isHighlighted: Bool
    /// Optional thumbnail; only the episode picker fills this in.
    /// Other dropdowns (audio, subtitle, speed) leave it nil and the
    /// row falls back to the compact text-only layout.
    var imageURL: URL? = nil
}

// MARK: - Dropdown Row

private extension TransportBar {
    @ViewBuilder
    func dropdownRow(item: DropdownItem, hasImages: Bool, rowHeight: CGFloat) -> some View {
        HStack(spacing: 14) {
            if hasImages {
                AsyncCachedImage(url: item.imageURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.white.opacity(0.08))
                }
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text(item.title)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer()

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
