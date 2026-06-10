import SwiftUI
import AetherEngine

/// Right-anchored "stats for nerds" panel mounted over the player. Only
/// visible when `PlaybackPreferences.showStatsForNerds` is on and the
/// transport bar's info chip has been pressed (see PlayerHostController). Read-
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
    /// Timer-sampled telemetry lives on a separate ObservableObject
    /// since the engine.diagnostics split (the engine's
    /// objectWillChange no longer fires on 1 Hz samples), so the
    /// panel observes it explicitly. Only mounted while the panel is
    /// open, so the 1 Hz re-render stays scoped to this view.
    @ObservedObject var diagnostics: EngineDiagnostics
    let item: JellyfinItem
    /// Active subtitle stream's container index (matches
    /// `MediaStream.index`), or `nil` when subtitles are off.
    let activeSubtitleIndex: Int?
    /// Cursor into `PlayerViewModel.statsSectionAnchors`, written by
    /// the press handlers in `PlayerView` while the panel is open.
    /// Used to drive the embedded `ScrollViewReader` to the section
    /// the user navigated to with the Up/Down arrows.
    let scrollSectionIndex: Int
    /// Whether to render the Engine/Buffer/Network diagnostic sections
    /// at the bottom of the panel. Driven by
    /// `PlaybackPreferences.showEngineDiagnostics`.
    let showEngineDiagnostics: Bool

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
        // press routing happens in PlayerHostController's @objc handlers, gated
        // on viewModel.showStatsOverlay.
    }

    /// Latches true once the panel's slide-in transition has settled,
    /// gating the ScrollViewReader's `scrollTo` so it doesn't race
    /// the entrance animation. Without the gate, the
    /// `statsSectionIndex = 0` reset in `PlayerViewModel.showStatsOverlay`'s
    /// didSet (which fires the same render cycle the overlay mounts)
    /// triggered a scrollTo whose own 0.2 s animation fought the
    /// panel's 0.25 s `.move(edge: .trailing)` transition, sometimes
    /// leaving the panel stuck halfway in for ~1 s. After the latch
    /// flips the user's up / down navigation drives scrollTo normally.
    @State private var didFinishAppearTransition = false

    private var panel: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("player.stats.title")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    liveSection
                        .id(PlayerViewModel.statsSectionAnchors[0])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 0))
                    playbackSection
                        .id(PlayerViewModel.statsSectionAnchors[1])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 1))
                    videoSection
                        .id(PlayerViewModel.statsSectionAnchors[2])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 2))
                    audioSection
                        .id(PlayerViewModel.statsSectionAnchors[3])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 3))
                    subtitleSection
                        .id(PlayerViewModel.statsSectionAnchors[4])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 4))
                    fileSection
                        .id(PlayerViewModel.statsSectionAnchors[5])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 5))
                    if showEngineDiagnostics {
                        engineSection
                            .id(PlayerViewModel.statsSectionAnchors[6])
                            .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 6))
                        bufferSection
                            .id(PlayerViewModel.statsSectionAnchors[7])
                            .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 7))
                        networkSection
                            .id(PlayerViewModel.statsSectionAnchors[8])
                            .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 8))
                    }
                }
                .padding(28)
                .frame(width: 560, alignment: .topLeading)
            }
            .onChange(of: scrollSectionIndex) { _, newIndex in
                // Skip the auto-scroll while the panel is still
                // sliding in; the mount-time reset to index 0 fires
                // this change during the entrance transition and the
                // two animations conflict. The content's already at
                // the top anyway since the ScrollView mounts there
                // by default, so suppressing the initial scrollTo
                // costs nothing.
                guard didFinishAppearTransition else { return }
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
        .task {
            // Wait past the entrance transition (0.25 s in PlayerHostController's
            // `.animation(.easeInOut(duration: 0.25), value:
            // viewModel.showStatsOverlay)`) plus a small buffer before
            // unlatching the scrollTo gate. After this point user
            // navigation triggers scrolls normally.
            try? await Task.sleep(for: .milliseconds(300))
            didFinishAppearTransition = true
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var liveSection: some View {
        section("player.stats.section.live") {
            let telemetry = diagnostics.liveTelemetry
            // Bitrate (instant + average)
            row(
                "player.stats.bitrate",
                value: Self.formatBitratePair(
                    instant: telemetry?.instantBitrateMbps,
                    average: telemetry?.averageBitrateMbps
                )
            )
            // Buffer (seconds + cached MB)
            row(
                "player.stats.buffer",
                value: Self.formatBufferPair(
                    seconds: telemetry?.forwardBufferSeconds,
                    cachedBytes: telemetry?.cachedBytes
                )
            )
            // Network (throughput + transferred bytes)
            row(
                "player.stats.network",
                value: Self.formatNetworkPair(
                    mbps: telemetry?.networkThroughputMbps,
                    transferred: telemetry?.networkTransferredBytes
                )
            )
            if let dropped = telemetry?.droppedFrameCount {
                row("player.stats.droppedFrames", value: "\(dropped)")
            }
            if let fps = telemetry?.observedFps {
                row("player.stats.fpsObserved", value: String(format: "%.2f fps", fps))
            }
            if let gap = telemetry?.avSyncGapMs {
                row(
                    "player.stats.avGap",
                    value: Self.formatAVGap(gap),
                    valueColor: Self.avGapColor(gap)
                )
            }
        }
    }

    private var playbackSection: some View {
        section("player.stats.section.playback") {
            row("player.stats.backend", value: backendLabel)
            if let decoder = player.activeVideoDecoder {
                row("player.stats.videoDecoder", value: decoder)
            }
            if let decoder = player.activeAudioDecoder {
                row("player.stats.audioDecoder", value: decoder)
            }
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
                row("player.stats.dynamicRange", value: videoRangeLabel(stream: v))
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
                if let bps = activeAudioStream?.bitRate, bps > 0 {
                    row("detail.tech.bitrate", value: Self.formatBitrate(bps))
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

    @ViewBuilder
    private var engineSection: some View {
        if let telemetry = diagnostics.liveTelemetry {
            section("player.stats.section.engine") {
                row("player.stats.producerRestarts", value: "\(telemetry.producerRestartCount)")
                row("player.stats.rss", value: "\(telemetry.rssMb) MB")
            }
        }
    }

    @ViewBuilder
    private var bufferSection: some View {
        if let telemetry = diagnostics.liveTelemetry {
            section("player.stats.section.buffer") {
                row(
                    "player.stats.demuxerBytes",
                    value: Self.formatByteCount(telemetry.demuxerBytesFetched)
                )
                row(
                    "player.stats.muxedBytes",
                    value: Self.formatByteCount(telemetry.muxedBytesLifetime)
                )
                row(
                    "player.stats.audioBridge",
                    value: Self.formatByteCountShort(telemetry.audioBridgeLiveBytes)
                )
            }
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        if let telemetry = diagnostics.liveTelemetry {
            section("player.stats.section.network") {
                row(
                    "player.stats.serverSent",
                    value: Self.formatByteCount(telemetry.serverBytesSentLifetime)
                )
                row(
                    "player.stats.serverRequests",
                    value: "\(telemetry.serverRequestCount)"
                )
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
        row(labelKey, value: value, valueColor: .white)
    }

    /// Same as `row(_:value:)` but lets the caller tint the value column.
    /// Currently used by the live A/V-gap row to colour-code the gap
    /// magnitude (green / yellow / red); other callers stay at white via
    /// the convenience overload above. The label column is intentionally
    /// not coloured: it has to stay legible across all locales.
    private func row(
        _ labelKey: LocalizedStringKey,
        value: String,
        valueColor: Color
    ) -> some View {
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
                .foregroundStyle(valueColor)
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
        case .aether, .none, .audio:
            // .aether is the legacy backend the engine no longer
            // dispatches to; reachable only via a stale enum value.
            // .audio is the lean audio-only path, which drives its own
            // music UI, not this video stats overlay, so it can't surface
            // here either. Collapse all into the placeholder rather than
            // carrying a localised string for backends that can't surface.
            return "—"
        }
    }

    /// Source-detected video range, refined with Jellyfin's source DV
    /// profile when the engine reports Dolby Vision. When the panel
    /// can't present the source (DV / HDR10 source on an SDR panel, or
    /// Match Content off) the engine clamps `videoFormat` to `.sdr` to
    /// match what's actually on screen; in that case render
    /// "Source → Target" so the row labels both the file and the
    /// rendering. Examples: "SDR", "HDR10+", "Dolby Vision P5",
    /// "Dolby Vision P5 → SDR", "Dolby Vision P8 → HDR10".
    private func videoRangeLabel(stream: MediaStream) -> String {
        let source = Self.formatLabel(player.sourceVideoFormat, dvProfile: stream.dvProfile)
        let effective = Self.formatLabel(player.videoFormat, dvProfile: stream.dvProfile)
        if source == effective {
            return source
        }
        return "\(source) → \(effective)"
    }

    private static func formatLabel(_ format: VideoFormat, dvProfile: Int?) -> String {
        let base: String
        switch format {
        case .sdr:         base = "SDR"
        case .hdr10:       base = "HDR10"
        case .hdr10Plus:   base = "HDR10+"
        case .dolbyVision: base = "Dolby Vision"
        case .hlg:         base = "HLG"
        }
        if format == .dolbyVision, let p = dvProfile {
            return "\(base) P\(p)"
        }
        return base
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

    private static func formatBitratePair(instant: Double?, average: Double?) -> String {
        let inst = instant.map { String(format: "%.1f Mbps", $0) } ?? "—"
        let avg = average.map { String(format: "%.1f", $0) } ?? "—"
        return "\(inst)  ·  avg \(avg) Mbps"
    }

    private static func formatBufferPair(seconds: Double?, cachedBytes: Int64?) -> String {
        let sec = seconds.map { String(format: "+%.1f s", $0) } ?? "—"
        let mb = cachedBytes.map { String(format: "%d MB", $0 / 1_048_576) } ?? "—"
        return "\(sec)  ·  \(mb) cached"
    }

    private static func formatNetworkPair(mbps: Double?, transferred: Int64?) -> String {
        let m = mbps.map { String(format: "%.1f Mbps", $0) } ?? "—"
        let t = transferred.map { Self.formatByteCount($0) } ?? "—"
        return "\(m)  ·  \(t)"
    }

    private static func formatAVGap(_ ms: Double) -> String {
        return String(format: "%.0f ms", ms)
    }

    /// Tints the live A/V-gap value by magnitude. Thresholds mirror the
    /// engine's existing `abs(gapMs) > 50` warn-log site, so the user-
    /// visible "this is hot" cue matches what we'd log internally.
    private static func avGapColor(_ ms: Double) -> Color {
        let abs = Swift.abs(ms)
        if abs < 50 { return .green }
        if abs < 150 { return .yellow }
        return .red
    }

    private static func formatByteCount(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    private static func formatByteCountShort(_ bytes: Int) -> String {
        return formatByteCount(Int64(bytes))
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
