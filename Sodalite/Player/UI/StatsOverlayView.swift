import SwiftUI
import AetherEngine

/// Right-anchored "stats for nerds" panel mounted over the player. Only
/// visible when `PlaybackPreferences.showStatsForNerds` is on and the
/// transport bar's info chip has been pressed (see PlayerView). Each
/// section (Playback / Video / Audio / Subtitles / File) is its own
/// focusable element, so the tvOS focus engine handles up/down
/// navigation natively and auto-scrolls the focused section into view.
/// Select / Menu close the panel via the PlayerView's @objc press
/// handlers, which see `viewModel.showStatsOverlay` and dismiss.
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

    /// Sections in display order. The focus engine moves between
    /// these via up/down; @ViewBuilder-conditional sections (empty
    /// video / audio / subtitle / file data) are simply omitted from
    /// the focus chain when not rendered, so navigation skips them
    /// without an explicit guard.
    private enum SectionID: Hashable {
        case playback, video, audio, subtitle, file
    }

    /// Owns first focus when the overlay mounts so the user lands on
    /// the Playback section instead of an arbitrary other element.
    /// `nil` is the "no overlay focus" state (overlay closed or just
    /// dismissed); setting it to `.playback` during `onAppear` is what
    /// pulls focus into the panel.
    @FocusState private var focusedSection: SectionID?

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
    }

    private var panel: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Text("player.stats.title")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                playbackSection
                videoSection
                audioSection
                subtitleSection
                fileSection
            }
            .padding(28)
            .frame(width: 560, alignment: .topLeading)
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
        .onAppear {
            // Pull focus into the panel so the focus engine's up/down
            // arrows navigate between sections instead of falling
            // through to the transport bar behind. .playback is always
            // rendered (no conditional gate) so this never lands on a
            // non-existent target.
            focusedSection = .playback
        }
    }

    // MARK: - Sections

    private var playbackSection: some View {
        FocusableSection(id: .playback, focusBinding: $focusedSection) {
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
    }

    @ViewBuilder
    private var videoSection: some View {
        if let v = videoStream {
            FocusableSection(id: .video, focusBinding: $focusedSection) {
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
    }

    @ViewBuilder
    private var audioSection: some View {
        // Prefer the engine's TrackInfo (carries the live Atmos flag and
        // channel count the host wouldn't otherwise know about) and fall
        // back to the Jellyfin MediaStream when the engine hasn't
        // resolved one yet (very brief window at session start).
        let engineTrack = player.audioTracks.first(where: { $0.id == player.activeAudioTrackIndex })
        if engineTrack != nil || activeAudioStream != nil {
            FocusableSection(id: .audio, focusBinding: $focusedSection) {
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
    }

    @ViewBuilder
    private var subtitleSection: some View {
        if activeSubtitleIndex != nil {
            FocusableSection(id: .subtitle, focusBinding: $focusedSection) {
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
    }

    @ViewBuilder
    private var fileSection: some View {
        if let source = mediaSource {
            FocusableSection(id: .file, focusBinding: $focusedSection) {
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

/// Wraps one stats section in the standard focusable-tile presentation
/// shared with `ChangelogListView.HighlightRow` and the settings tiles:
/// background fill + accent-tint stroke + scale + shadow that animate
/// in when the row receives focus. The id-keyed focused binding lets
/// the overlay control which section starts focused on mount.
private struct FocusableSection<ID: Hashable, Content: View>: View {
    let id: ID
    let focusBinding: FocusState<ID?>.Binding
    @ViewBuilder var content: Content

    @FocusState private var isFocused: Bool

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isFocused ? .white.opacity(0.15) : .white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 12, y: 6)
            .animation(.easeInOut(duration: 0.18), value: isFocused)
            .focusable()
            .focused($isFocused)
            .focused(focusBinding, equals: id)
    }
}
