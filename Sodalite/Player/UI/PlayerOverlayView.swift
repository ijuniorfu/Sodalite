import SwiftUI
import AetherEngine

// MARK: - Overlay View (display-only SwiftUI)

/// Display-only overlay mounted over the AVPlayerViewController by `PlayerHostController`; all state reads from `PlayerViewModel`, input handled by the UIKit host (hence `.allowsHitTesting(false)` where it would otherwise capture focus).
struct PlayerOverlayView: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void
    /// Literal player tint (the host's `.tint(...)` value) passed explicitly because the subtitle-search overlay needs a concrete `Color` for focused-row fills, not just the environment tint.
    var tintColor: Color? = nil

    var body: some View {
        ZStack {
            #if os(iOS)
            // Bottom gesture layer: catches taps / swipes on the empty video area; the controls and
            // buttons render above it and win their own hits. Explicit fill: a plain UIView has no
            // intrinsic size and would otherwise collapse to 0x0 and receive no touches.
            PlayerGestureCatcher(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            #endif

            // Keep the styled ASS layer mounted even while the cue array is momentarily empty (seek resets); libass already holds the assembled script.
            if viewModel.assRenderer != nil || !viewModel.subtitleCues.isEmpty || !viewModel.secondarySubtitleCues.isEmpty {
                SubtitleOverlayView(
                    cues: viewModel.subtitleCues,
                    currentTime: viewModel.subtitleTime,
                    maxCueDuration: viewModel.subtitleMaxCueDuration,
                    secondaryCues: viewModel.secondarySubtitleCues,
                    secondaryMaxCueDuration: viewModel.secondarySubtitleMaxCueDuration,
                    fontSize: viewModel.preferences.subtitleFontSize,
                    textColor: viewModel.preferences.subtitleColor,
                    background: viewModel.preferences.subtitleBackground,
                    delaySeconds: viewModel.preferences.subtitleDelaySeconds,
                    verticalPosition: viewModel.preferences.subtitleVerticalPosition,
                    font: viewModel.preferences.subtitleFont,
                    weight: viewModel.preferences.subtitleWeight,
                    controlsVisible: viewModel.showControls,
                    assRenderer: viewModel.assRenderer,
                    assReloadSignal: viewModel.assReloadSignal,
                    activeSubtitleCodec: viewModel.activeSubtitleCodec,
                    hasSecondaryTrack: viewModel.activeSecondarySubtitleIndex != nil
                )
            }

            if viewModel.isLoading {
                // Inner ZStack + whole-stack ignoresSafeArea so the spinner shares the backdrop's coord space; centering on Color.black's layout bounds (which respect safe-area) drifted the spinner top-half when an outgoing next-episode card shifted the parent's insets.
                ZStack {
                    Color.black
                    ProgressView()
                        // ProgressView doesn't reliably inherit the overlay's `.tint(...)` on tvOS (falls back to white); set it explicitly.
                        .tint(tintColor ?? .accentColor)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }

            if let error = viewModel.errorMessage {
                ZStack {
                    Color.black
                    VStack(spacing: 20) {
                        Image(systemName: viewModel.errorIcon ?? "exclamationmark.triangle")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                        if let title = viewModel.errorTitle {
                            Text(title)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                        }
                        Text(error)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 720)
                        Button {
                            onDismiss()
                        } label: {
                            Text("player.error.back")
                                .font(.body)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(SettingsTileButtonStyle())
                        .padding(.top, 8)
                    }
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }

            if viewModel.showControls && !viewModel.isLoading && viewModel.errorMessage == nil {
                controlsOverlay
            }

            // Stats-for-nerds panel mounted above the controls overlay so it stays readable when the transport's auto-hide fires.
            if viewModel.showStatsOverlay && viewModel.errorMessage == nil {
                StatsOverlayView(
                    player: viewModel.player,
                    diagnostics: viewModel.player.diagnostics,
                    item: viewModel.item,
                    activeSubtitleIndex: viewModel.activeSubtitleIndex,
                    scrollSectionIndex: viewModel.statsSectionIndex,
                    showEngineDiagnostics: viewModel.preferences.showEngineDiagnostics
                )
            }

            topRightInfoColumn

            // Two-gate: diagnostic build (DEBUG/TestFlight) AND showDiagnosticOverlay (defaults off so it isn't over every TestFlight session).
            if LogTap.isDiagnosticBuild && viewModel.preferences.showDiagnosticOverlay {
                DiagnosticLogOverlay(focusOnDV: viewModel.preferences.focusDiagnosticOverlayOnDV)
            }

            // Floating Skip Intro hint, only while controls are hidden; once they open, the skip action is a focusable button inside TransportBar instead.
            if viewModel.isInsideIntro
                && !viewModel.showControls
                && viewModel.errorMessage == nil
                && !viewModel.showNextEpisodeOverlay {
                introSkipOverlay
            }

            if viewModel.showNextEpisodeOverlay,
               let next = viewModel.nextEpisode {
                nextEpisodeOverlay(next)
            }

            #if os(iOS)
            // Transient brightness/volume/skip HUD, centered above the controls (kept mounted so the
            // opacity fade animates cleanly).
            PlayerHUD(kind: viewModel.hudKind ?? .skipForward, level: viewModel.hudLevel)
                .opacity(viewModel.hudKind == nil ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: viewModel.hudKind)
                .allowsHitTesting(false)
                .zIndex(60)
            #endif

            // Subtitle search overlay (Feature #4); uses literal player tint so focused rows fill with the server accent, not white.
            if viewModel.subtitleSearchVisible {
                SubtitleSearchView(
                    viewModel: viewModel,
                    tint: tintColor ?? .accentColor
                )
                .transition(.opacity)
                .zIndex(50)
            }

            if viewModel.isSubtitleDeletePromptVisible {
                SubtitleDeletePromptView(
                    viewModel: viewModel,
                    tint: tintColor ?? .accentColor
                )
                .transition(.opacity)
                .zIndex(51)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.isLoading)
        .animation(.easeInOut(duration: 0.3), value: viewModel.showControls)
        .animation(.easeInOut(duration: 0.3), value: viewModel.showNextEpisodeOverlay)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isInsideIntro)
        .animation(.easeInOut(duration: 0.25), value: viewModel.showStatsOverlay)
        .animation(.easeInOut(duration: 0.3), value: viewModel.subtitleSearchVisible)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isSubtitleDeletePromptVisible)
    }

    private var introSkipOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                skipIntroHint
                    #if os(iOS)
                    .padding(.trailing, 24)
                    .padding(.bottom, 28)
                    #else
                    .padding(.trailing, 80)
                    .padding(.bottom, 80)
                    #endif
            }
        }
        // ignoresSafeArea pins the hint to the true screen bottom: alpha=0 AVKit chrome (kept for the CC +10s handler via playbackControlsIncludeTransportBar) still widens contentOverlayView's bottom safe-area inset, which would shift a Spacer-anchored hint mid-screen at session start.
        .ignoresSafeArea()
        .transition(.move(edge: .bottom).combined(with: .opacity))
        #if os(tvOS)
        .allowsHitTesting(false)
        #endif
    }

    private var skipIntroHint: some View {
        #if os(iOS)
        let labelFont = Font.subheadline
        let hPad: CGFloat = 18
        let vPad: CGFloat = 11
        #else
        let labelFont = Font.body
        let hPad: CGFloat = 24
        let vPad: CGFloat = 14
        #endif
        let content = HStack(spacing: 10) {
            Image(systemName: "forward.end.fill")
                .font(labelFont)
            Text(String(localized: "player.skipIntro", defaultValue: "Skip Intro"))
                .font(labelFont)
                .fontWeight(.semibold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        #if os(iOS)
        return Button { viewModel.skipIntro() } label: { content }.buttonStyle(.plain)
        #else
        return content
        #endif
    }

    private func nextEpisodeOverlay(_ episode: JellyfinItem) -> some View {
        // Absolute scene-screen `.position(x:,y:)` instead of frame/alignment anchors: at end-of-playback playNextEpisode tears down AVKit chrome, collapsing the SwiftUI parent's frame for ~100 ms, so any alignment-based anchor recomputes against the shrunken parent and drifts the card mid-screen. Scene-derived screen (not deprecated UIScreen.main); 1080p fallback is the impossible no-scene case.
        let screen = UIApplication.shared.connectedScenes
            .lazy.compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.size ?? CGSize(width: 1920, height: 1080)
        #if os(iOS)
        let cardW: CGFloat = 300
        let cardH: CGFloat = 169
        let marginX: CGFloat = 24
        let marginY: CGFloat = viewModel.showControls ? 150 : 28
        #else
        let cardW: CGFloat = 380
        let cardH: CGFloat = 214
        let marginX: CGFloat = viewModel.showControls ? 60 : 40
        let marginY: CGFloat = viewModel.showControls ? 300 : 40
        #endif
        return nextEpisodeCard(for: episode, width: cardW, height: cardH)
            .position(
                x: screen.width - cardW / 2 - marginX,
                y: screen.height - cardH / 2 - marginY
            )
            .ignoresSafeArea()
            // Asymmetric: slide in from trailing, fade-only on removal. Symmetric `.move(edge: .trailing)` removal composed with the end-of-playback parent reflow and exposed the drift-to-middle symptom; fade has no spatial component to disrupt.
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            ))
    }

    @ViewBuilder
    private func nextEpisodeCard(for episode: JellyfinItem, width: CGFloat, height: CGFloat) -> some View {
        #if os(iOS)
        // Tappable on touch; tvOS commits via the Select press machine.
        Button { Task { await viewModel.playNextEpisode() } } label: {
            cardBody(for: episode, width: width, height: height)
        }
        .buttonStyle(.plain)
        #else
        cardBody(for: episode, width: width, height: height)
        #endif
    }

    private func cardBody(for episode: JellyfinItem, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Explicit frame + clipped() required: otherwise the image's intrinsic size leaks into ZStack sizing and a portrait fallback (series poster) blows the card into a tall portrait.
            if let imageURL = episodeThumbnailURL(for: episode) {
                // AsyncCachedImage, not AsyncImage: the card mounts/unmounts with the overlay, and raw AsyncImage re-fetched the thumbnail each time at the worst moment (end of episode, next-item prefetch).
                AsyncCachedImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.clear
                }
                .frame(width: width, height: height)
                .clipped()
                .opacity(0.4)
            }

            VStack(alignment: .leading, spacing: 0) {
                // Episodes show "Next Episode"; a movie reached via a shuffle queue shows "Up Next" (the S/E label below is naturally hidden for movies).
                Text(episode.type == .episode
                     ? String(localized: "player.nextEpisode", defaultValue: "Next Episode")
                     : String(localized: "player.upNext", defaultValue: "Up Next"))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))

                Spacer(minLength: 8)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let s = episode.parentIndexNumber, let e = episode.indexNumber {
                        Text("S\(s)E\(e)")
                            .foregroundStyle(.white.opacity(0.85))
                            .layoutPriority(1)
                    }
                    Text(episode.name)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .font(.body)
                .fontWeight(.semibold)

                Spacer(minLength: 8)

                if viewModel.isCountdownActive, viewModel.nextEpisodeCountdown > 0 {
                    Text("player.nextEpisode.countdown \(viewModel.nextEpisodeCountdown)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .padding(20)
            .frame(width: width, height: height, alignment: .topLeading)
        }
        // Fixed 16:9: image and content share the explicit 380x214 frame so nothing intrinsic-leaking can stretch the ZStack into a portrait.
        .frame(width: width, height: height)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    /// Build episode thumbnail URL directly from item data
    /// (avoids needing JellyfinImageService in the player).
    private func episodeThumbnailURL(for item: JellyfinItem) -> URL? {
        guard let baseURL = viewModel.playbackService.baseURL else { return nil }
        if let tag = item.imageTags?.primary {
            return URL(string: "\(baseURL)/Items/\(item.id)/Images/Primary?tag=\(tag)&maxWidth=640&quality=80")
        }
        if let tags = item.backdropImageTags, let tag = tags.first {
            return URL(string: "\(baseURL)/Items/\(item.id)/Images/Backdrop?tag=\(tag)&maxWidth=640&quality=80")
        }
        if let tags = item.parentBackdropImageTags, let tag = tags.first, let seriesId = item.seriesId {
            return URL(string: "\(baseURL)/Items/\(seriesId)/Images/Backdrop?tag=\(tag)&maxWidth=640&quality=80")
        }
        return nil
    }

    @ViewBuilder
    private var controlsOverlay: some View {
        #if os(iOS)
        PlayerTouchControls(
            viewModel: viewModel,
            onDismiss: onDismiss,
            tintColor: tintColor,
            episodeImageURL: { episodeThumbnailURL(for: $0) },
            chapterThumbnail: { await viewModel.chapterThumbnail(forIndex: $0) }
        )
        #else
        tvOSControlsOverlay
        #endif
    }

    private var tvOSControlsOverlay: some View {
        // Pin to scene-screen bounds (same fix as the next-episode card): an audio-track switch reloads AVKit and transiently collapses its container frame, so a Spacer/alignment-anchored controls block jumps up while fading. Absolute screen-sized frame + center position removes the dependency on the churning AVKit parent.
        let screen = UIApplication.shared.connectedScenes
            .lazy.compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.size ?? CGSize(width: 1920, height: 1080)
        return ZStack {
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 300)
            }
            .ignoresSafeArea()

            VStack {
                LinearGradient(
                    colors: [.black.opacity(0.7), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 200)
                Spacer()
            }
            .ignoresSafeArea()

            // Title (top left); HDR + Speed badges live in topRightInfoColumn so the speed badge can persist after the transport hides.
            VStack {
                HStack(alignment: .top) {
                    PlayerTitleOverlay(item: viewModel.item)
                    Spacer()
                }
                Spacer()
            }
            .ignoresSafeArea()

            VStack {
                Spacer()
                if viewModel.isLiveSession {
                    LiveTransportBar(viewModel: viewModel)
                } else {
                TransportBar(
                    progress: viewModel.displayedProgress,
                    currentTime: viewModel.currentTime,
                    remainingTime: viewModel.remainingTime,
                    isScrubbing: viewModel.isScrubbing,
                    scrubTime: viewModel.scrubTime,
                    audioTracks: viewModel.displayAudioTracks,
                    subtitleStreams: viewModel.displaySubtitleStreams,
                    activeAudioIndex: viewModel.activeAudioIndex,
                    activeSubtitleIndex: viewModel.activeSubtitleIndex,
                    activeSecondarySubtitleIndex: viewModel.activeSecondarySubtitleIndex,
                    secondarySubtitleCandidates: viewModel.secondarySubtitleCandidates,
                    supportsSubtitleSearch: viewModel.supportsSubtitleSearch,
                    activeSpeedIndex: viewModel.activeSpeedIndex,
                    controlsFocus: viewModel.controlsFocus,
                    trackDropdown: viewModel.trackDropdown,
                    showSkipIntroButton: viewModel.isInsideIntro,
                    seasonEpisodes: viewModel.seasonEpisodes,
                    activeEpisodeID: viewModel.item.id,
                    episodeImageURL: { episodeThumbnailURL(for: $0) },
                    chapters: viewModel.chapters,
                    durationSeconds: viewModel.player.duration,
                    chapterThumbnail: { await viewModel.chapterThumbnail(forIndex: $0) },
                    pictureMode: viewModel.pictureMode,
                    showsInfoButton: viewModel.preferences.showStatsForNerds,
                    isStatsOverlayOpen: viewModel.showStatsOverlay,
                    previewImage: viewModel.scrubPreview.previewImage
                )
                }
            }
            .ignoresSafeArea()
        }
        .frame(width: screen.width, height: screen.height)
        .position(x: screen.width / 2, y: screen.height / 2)
        .ignoresSafeArea()
        .transition(.opacity)
    }
}

// MARK: - Top-Right Info Column

private extension PlayerOverlayView {
    /// Top-right informational badges: HDR follows transport visibility (matches Apple TV's player); speed badge persists whenever rate != 1.0x so a user who set 1.5x then hid the transport isn't silently at the wrong speed.
    var topRightInfoColumn: some View {
        VStack {
            HStack(alignment: .top) {
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    if viewModel.showControls && viewModel.videoFormat != .sdr {
                        VideoFormatBadge(format: viewModel.videoFormat)
                    }
                    if PlayerViewModel.speedOptions.indices.contains(viewModel.activeSpeedIndex),
                       PlayerViewModel.speedOptions[viewModel.activeSpeedIndex] != 1.0 {
                        SpeedBadge(index: viewModel.activeSpeedIndex)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.top, 68)
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeSpeedIndex)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showControls)
        .animation(.easeInOut(duration: 0.2), value: viewModel.videoFormat)
        .allowsHitTesting(false)
    }
}

// MARK: - Speed Badge

private struct SpeedBadge: View {
    let index: Int

    var body: some View {
        Text(TransportBar.speedLabel(for: index))
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .monospacedDigit()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
    }
}

// MARK: - Video Format Badge

private struct VideoFormatBadge: View {
    let format: VideoFormat

    var body: some View {
        Text(label)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
    }

    private var label: String {
        switch format {
        case .sdr:          return "SDR"
        case .hdr10:        return "HDR10"
        case .hdr10Plus:    return "HDR10+"
        case .dolbyVision:  return "Dolby Vision"
        case .hlg:          return "HLG"
        }
    }
}

// MARK: - Diagnostic Log Overlay

/// Top-left diagnostic HUD mirroring the engine's recent `print(...)` lines (DV detection, HDR10+ extraction, format upgrades) into the player UI so a beta tester can screenshot them without Console.app. Only mounted in DEBUG/TestFlight builds (`LogTap.isDiagnosticBuild`).
private struct DiagnosticLogOverlay: View {
    @ObservedObject private var tap = LogTap.shared
    let focusOnDV: Bool

    /// 50 rows at 16pt monospaced fills ~top 2/3 of 1080p, keeping the full session preamble AND the eventual AVPlayer failure on screen at once. Diagnostic-build only, so the occlusion never hits an App Store user.
    private let visibleCount = 50

    /// DV/HDR focus matchers: a line is kept if it contains ANY of these. Tuned so the support-thread diagnostic chain (dispatch, HLS routing, tracks, audio route, display criteria, panel signaling) stays in frame while per-segment cache/muxer chatter falls off.
    private static let focusSubstrings: [String] = [
        "[HLSVideoEngine]",
        "[NativeAVPlayerHost]",
        "[DisplayCriteria]",
        "[Profile]",
        "[AetherEngine] dispatch",
        "[AetherEngine] AVAudioSession",
        "[AetherEngine] HDR10+",
        "[AudioBridge]",
        "DV source",
        "WARNING",
    ]

    private var renderedLines: [String] {
        if focusOnDV {
            return Array(tap.lines.filter { line in
                Self.focusSubstrings.contains { line.contains($0) }
            }.suffix(visibleCount))
        }
        return Array(tap.lines.suffix(visibleCount))
    }

    var body: some View {
        VStack {
            // Full-width container so long diagnostic lines aren't truncated by lineLimit(1) (a bounded box once cut DrHurt's seg4 failure right before tb_out). Side padding (60/80) matches the player's safe-area gutters.
            VStack(alignment: .leading, spacing: 2) {
                let visible = renderedLines
                ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 16, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.black.opacity(0.55))
            )
            .padding(.leading, 60)
            .padding(.trailing, 80)
            .padding(.top, 60)
            Spacer()
        }
        .allowsHitTesting(false)
    }
}
