import SwiftUI
import AetherEngine

/// Right-anchored "stats for nerds" panel mounted over the player. Only
/// visible when `PlaybackPreferences.showStatsForNerds` is on and the
/// transport bar's info chip has been pressed (see PlayerView). Read-
/// only and non-focusable: the user opens it, scans the data, then
/// dismisses it via Menu or the same info chip.
///
/// Data sources are split between the engine and the Jellyfin item to
/// keep the labels honest:
///
/// - **Playback** (backend, decoder identity, runtime HDR format) comes
///   from `AetherEngine`'s @Published surface, observed live so an
///   audio-track-switch reload that flips the audio decoder description
///   updates the panel without the user having to re-open it.
/// - **Container metadata** (codec, resolution, frame rate, bitrate,
///   file size, filename) comes from `item.mediaStreams` /
///   `item.mediaSources`, which the detail fetch already pulls.
struct StatsOverlayView: View {
    @ObservedObject var player: AetherEngine
    let item: JellyfinItem
    /// Active subtitle stream's container index (matches
    /// `MediaStream.index`), or `nil` when subtitles are off.
    let activeSubtitleIndex: Int?
    /// Cursor into `PlayerViewModel.statsSectionAnchors`, written by
    /// the press handlers in `PlayerView` while the panel is open.
    /// Used to drive the embedded `ScrollViewReader` to the section
    /// the user navigated to with the Up/Down arrows.
    let scrollSectionIndex: Int

    private var videoStream: MediaStream? {
        item.mediaStreams?.first { $0.type == .video }
    }

    private var activeAudioStream: MediaStream? {
        guard let id = player.activeAudioTrackIndex else { return nil }
        return item.mediaStreams?.first { $0.type == .audio && $0.index == id }
    }

    private var activeSubtitleStream: MediaStream? {
        guard let id = activeSubtitleIndex else { return nil }
        return item.mediaStreams?.first { $0.type == .subtitle && $0.index == id }
    }

    private var mediaSource: MediaSource? {
        item.mediaSources?.first
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            panel
                .padding(.trailing, 40)
                .padding(.vertical, 40)
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
        // Pointer-style hit testing isn't needed (no tap targets), but
        // we leave it enabled so the underlying focus engine sees the
        // overlay as a layer that should consume gestures. Up/Down
        // press routing happens in PlayerView's @objc handlers, gated
        // on viewModel.showStatsOverlay.
    }

    private var panel: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("player.stats.title")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    playbackSection
                        .id(PlayerViewModel.statsSectionAnchors[0])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 0))
                    videoSection
                        .id(PlayerViewModel.statsSectionAnchors[1])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 1))
                    audioSection
                        .id(PlayerViewModel.statsSectionAnchors[2])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 2))
                    subtitleSection
                        .id(PlayerViewModel.statsSectionAnchors[3])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 3))
                    fileSection
                        .id(PlayerViewModel.statsSectionAnchors[4])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 4))
                }
                .padding(28)
                .frame(width: 560, alignment: .topLeading)
            }
            .onChange(of: scrollSectionIndex) { _, newIndex in
                let anchors = PlayerViewModel.statsSectionAnchors
                guard anchors.indices.contains(newIndex) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    // `.top` keeps the active section header at the top
                    // edge of the visible area, mirroring how the
                    // transport-bar dropdowns scroll their highlighted
                    // row into view.
                    proxy.scrollTo(anchors[newIndex], anchor: .top)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .frame(width: 560)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
    }

    // MARK: - Sections

    private var playbackSection: some View {
        section("player.stats.section.playback") {
            row("player.stats.backend", value: backendLabel)
            if let decoder = player.activeVideoDecoder {
                row("player.stats.videoDecoder", value: decoder)
            }
            if let decoder = player.activeAudioDecoder {
                row("player.stats.audioDecoder", value: decoder)
            }
            row("player.stats.dynamicRange", value: dynamicRangeLabel)
        }
    }

    @ViewBuilder
    private var videoSection: some View {
        if let v = videoStream {
            section("detail.tech.video") {
                if let codec = v.codec?.uppercased() {
                    let profile = v.profile ?? ""
                    row(
                        "detail.tech.codec",
                        value: profile.isEmpty ? codec : "\(codec) \(profile)"
                    )
                }
                if let w = v.width, let h = v.height {
                    row("detail.tech.resolution", value: "\(w)×\(h)")
                }
                if let fps = v.realFrameRate ?? v.averageFrameRate {
                    row("detail.tech.framerate", value: String(format: "%.3g fps", fps))
                }
                if let bps = mediaSource?.bitrate {
                    row("detail.tech.bitrate", value: Self.formatBitrate(bps))
                }
            }
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        // Prefer the engine's TrackInfo (carries the live Atmos flag and
        // channel count the host wouldn't otherwise know about) and fall
        // back to the Jellyfin MediaStream when the engine hasn't
        // resolved one yet (very brief window at session start).
        let engineTrack = player.audioTracks.first(where: { $0.id == player.activeAudioTrackIndex })
        if engineTrack != nil || activeAudioStream != nil {
            section("detail.tech.audio") {
                if let codec = engineTrack?.codec.uppercased()
                    ?? activeAudioStream?.codec?.uppercased() {
                    row("detail.tech.codec", value: codec)
                }
                let channels = engineTrack?.channels ?? activeAudioStream?.channels ?? 0
                let isAtmos = engineTrack?.isAtmos ?? false
                if channels > 0 {
                    row(
                        "detail.tech.channels",
                        value: isAtmos
                            ? "\(Self.channelLayoutLabel(channels)) · Atmos"
                            : Self.channelLayoutLabel(channels)
                    )
                }
                if let lang = activeAudioStream?.displayTitle
                    ?? engineTrack?.language
                    ?? activeAudioStream?.language {
                    row("detail.tech.language", value: lang)
                }
            }
        }
    }

    @ViewBuilder
    private var subtitleSection: some View {
        if activeSubtitleIndex != nil {
            section("detail.tech.subtitles") {
                if let codec = activeSubtitleStream?.codec?.uppercased() {
                    row("detail.tech.codec", value: codec)
                }
                if let lang = activeSubtitleStream?.displayTitle
                    ?? activeSubtitleStream?.language {
                    row("detail.tech.language", value: lang)
                }
                if activeSubtitleStream?.isForced == true {
                    row("player.stats.forced", value: "✓")
                }
            }
        }
    }

    @ViewBuilder
    private var fileSection: some View {
        if let source = mediaSource {
            section("detail.tech.file") {
                if let container = source.container?.uppercased() {
                    row("detail.tech.format", value: container)
                }
                if let size = source.size {
                    row("detail.tech.size", value: Self.formatFileSize(size))
                }
                if let path = source.path,
                   let filename = path.split(separator: "/").last {
                    row("detail.tech.filename", value: String(filename))
                }
            }
        }
    }

    // MARK: - Row + Section primitives

    private func section<C: View>(
        _ titleKey: LocalizedStringKey,
        @ViewBuilder _ content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleKey)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tint)
                .textCase(.uppercase)
                .padding(.bottom, 2)
            content()
        }
    }

    private func row(_ labelKey: LocalizedStringKey, value: String) -> some View {
        // 180pt label column carries the longer German + Romance-
        // language terms ("Dynamikbereich", "Décodeur vidéo",
        // "Decodificador de áudio") on a single line. English labels
        // (~7 chars) read slightly loose at this width, an acceptable
        // trade for not truncating mid-word in the other 25 locales.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(labelKey)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 180, alignment: .leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.caption)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Labels

    private var backendLabel: String {
        switch player.playbackBackend {
        case .native:
            return String(localized: "player.stats.backend.native", defaultValue: "Native (AVPlayer)")
        case .software:
            return String(localized: "player.stats.backend.software", defaultValue: "Software (dav1d / FFmpeg)")
        case .aether, .none:
            // .aether is the legacy backend the engine no longer
            // dispatches to; reachable only via a stale enum value.
            // Collapse both into the placeholder rather than carrying
            // a localised string for a backend that can't surface.
            return "—"
        }
    }

    private var dynamicRangeLabel: String {
        switch player.videoFormat {
        case .sdr:        return "SDR"
        case .hdr10:      return "HDR10"
        case .hdr10Plus:  return "HDR10+"
        case .dolbyVision: return "Dolby Vision"
        case .hlg:        return "HLG"
        }
    }

    // MARK: - Formatters

    private static func channelLayoutLabel(_ channels: Int) -> String {
        switch channels {
        case 1: return String(localized: "tech.channels.mono", defaultValue: "Mono")
        case 2: return String(localized: "tech.channels.stereo", defaultValue: "Stereo")
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    private static func formatBitrate(_ bps: Int) -> String {
        let mbps = Double(bps) / 1_000_000
        if mbps >= 1 { return String(format: "%.1f Mbps", mbps) }
        return "\(bps / 1000) Kbps"
    }

    private static func formatFileSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

/// Highlights the section the up/down cursor currently sits on with a
/// background fill + accent-tint stroke. Read-only visual indicator,
/// not focusable: the sections aren't reachable through the focus
/// engine (the AVKit-host gesture recognizers eat arrow-key presses
/// before the engine sees them), so the cursor is driven by the same
/// @objc press handlers that drive scrollTo. This modifier just makes
/// the cursor's position visible.
private struct StatsSectionHighlight: ViewModifier {
    let isCurrent: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isCurrent ? .white.opacity(0.12) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isCurrent ? 1 : 0)
            )
            .animation(.easeInOut(duration: 0.18), value: isCurrent)
    }
}
