import SwiftUI
import AetherEngine

/// Right-anchored read-only "stats for nerds" panel; visible when `PlaybackPreferences.showStatsForNerds` is on and the transport's info chip is pressed. Data is split for honesty: Playback (backend, decoder, runtime HDR) from `AetherEngine`'s @Published surface (observed live so an audio-track-switch reload updates it in place); container metadata (codec/resolution/fps/bitrate/size/filename) from `item.mediaStreams`/`mediaSources`.
struct StatsOverlayView: View {
    @ObservedObject var player: AetherEngine
    /// Timer-sampled telemetry observed separately since the engine.diagnostics split (engine's objectWillChange no longer fires on 1 Hz samples). Mounted only while the panel is open, scoping the 1 Hz re-render to this view.
    @ObservedObject var diagnostics: EngineDiagnostics
    let item: JellyfinItem
    /// Active subtitle stream's container index (matches `MediaStream.index`), or `nil` when off.
    let activeSubtitleIndex: Int?
    /// Cursor into `PlayerViewModel.statsSectionAnchors`, written by PlayerView's press handlers to drive the ScrollViewReader to the Up/Down-navigated section.
    let scrollSectionIndex: Int
    /// Renders the Engine/Buffer/Network sections; driven by `PlaybackPreferences.showEngineDiagnostics`.
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
        // Hit testing left on so the focus engine treats the overlay as a gesture-consuming layer; Up/Down routing is in PlayerHostController's @objc handlers gated on viewModel.showStatsOverlay.
    }

    /// Latches once the slide-in settles, gating scrollTo so the mount-time `statsSectionIndex = 0` reset (fires the same render cycle) doesn't run a 0.2s scrollTo that fights the panel's 0.25s `.move(edge: .trailing)` transition (stuck-halfway-in for ~1s).
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
                // Skip auto-scroll while sliding in (the mount-time index-0 reset fires here and the two animations conflict); content starts at top anyway.
                guard didFinishAppearTransition else { return }
                let anchors = PlayerViewModel.statsSectionAnchors
                guard anchors.indices.contains(newIndex) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    // `.top` keeps the active section header at the top edge, mirroring transport-bar dropdowns.
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
            // Wait past the 0.25s entrance transition (+ buffer) before unlatching the scrollTo gate.
            try? await Task.sleep(for: .milliseconds(300))
            didFinishAppearTransition = true
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var liveSection: some View {
        section("player.stats.section.live") {
            let telemetry = diagnostics.liveTelemetry
            row(
                "player.stats.bitrate",
                value: Self.formatBitratePair(
                    instant: telemetry?.instantBitrateMbps,
                    average: telemetry?.averageBitrateMbps
                )
            )
            row(
                "player.stats.buffer",
                value: Self.formatBufferPair(
                    seconds: telemetry?.forwardBufferSeconds,
                    cachedBytes: telemetry?.cachedBytes
                )
            )
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
        // Prefer the engine's TrackInfo (live Atmos flag + channel count); fall back to the Jellyfin MediaStream during the brief session-start window before the engine resolves one.
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

    /// `row(_:value:)` with a caller-tinted value column (used by the live A/V-gap row for green/yellow/red); label column stays uncoloured for cross-locale legibility.
    private func row(
        _ labelKey: LocalizedStringKey,
        value: String,
        valueColor: Color
    ) -> some View {
        // 180pt label column fits the longer German/Romance terms ("Dynamikbereich", "Décodeur vidéo") on one line, trading slight English looseness for no mid-word truncation in the other 25 locales.
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
            // .aether is legacy (no longer dispatched to); .audio drives its own music UI, not this video overlay. Neither can surface here, so collapse to the placeholder.
            return "—"
        }
    }

    /// Source video range refined with Jellyfin's DV profile. When the engine clamps `videoFormat` to `.sdr` (DV/HDR10 source on SDR panel, or Match Content off), render "Source → Target" (e.g. "Dolby Vision P5 → SDR", "Dolby Vision P8 → HDR10").
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

    /// Tints the A/V-gap value by magnitude; thresholds mirror the engine's `abs(gapMs) > 50` warn-log site.
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

/// Visual-only highlight (fill + accent stroke) for the up/down cursor's section; not focusable (AVKit-host gesture recognizers eat arrow presses before the focus engine), so the cursor is driven by the same @objc handlers that drive scrollTo.
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
