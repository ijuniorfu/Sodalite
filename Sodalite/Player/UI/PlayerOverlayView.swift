import SwiftUI
import AetherEngine

// MARK: - Overlay View (display-only SwiftUI)

/// SwiftUI overlay mounted on top of the AVPlayerViewController by
/// `PlayerHostController`. Pure display: every piece of state the
/// view reads comes from `PlayerViewModel`. Input (presses, scrubs)
/// is handled by the UIKit host and never by this view, which is
/// why everything sits behind `.allowsHitTesting(false)` where it
/// would otherwise capture focus.
struct PlayerOverlayView: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void
    /// Concrete player tint, threaded from `PlayerHostController` (the same
    /// `tintColor` the host applies to the overlay via `.tint(...)`). The
    /// display-only overlay leans on the environment tint for its shape-style
    /// fills, but the subtitle-search overlay needs the literal `Color` for
    /// focused-row fills, so the value is passed in explicitly.
    var tintColor: Color? = nil

    var body: some View {
        ZStack {
            // The styled ASS layer must stay mounted even while the
            // engine's cue array is momentarily empty (seek resets),
            // libass already holds the assembled script.
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
                // Inner ZStack so the spinner lives in the same coord
                // space as the full-screen black backdrop, then the
                // whole stack ignoresSafeArea together. Earlier form
                // (`Color.black.ignoresSafeArea().overlay(ProgressView())`)
                // centered the spinner on Color.black's *layout*
                // bounds, which still respect safe-area insets, so when
                // an outgoing overlay (next-episode card transitioning
                // out) shifted the parent's effective insets the
                // spinner landed in the top half of the screen instead
                // of the visible centre.
                ZStack {
                    Color.black
                    ProgressView()
                        // The host applies `.tint(...)` to the overlay, but
                        // the activity indicator does not inherit it reliably
                        // on tvOS, it falls back to white. Set it explicitly.
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

            // Stats-for-nerds side panel (right-anchored). Mounted on
            // top of the controls overlay so it stays readable when the
            // transport bar's auto-hide timer fires; press the info
            // chip or Menu to dismiss.
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

            // Top-right info column, HDR badge (only with controls,
            // matches Apple TV's own player) and Speed badge (always
            // when rate ≠ 1.0× so the user remembers they sped things
            // up after the transport hides). Stacks vertically when
            // both are visible.
            topRightInfoColumn

            // Diagnostic log overlay (top-left). Two-gate: the build
            // has to be DEBUG or TestFlight (App Store users can't
            // even toggle this on), AND the user has to have flipped
            // showDiagnosticOverlay in Settings, which defaults off
            // so the overlay isn't on top of every TestFlight session.
            if LogTap.isDiagnosticBuild && viewModel.preferences.showDiagnosticOverlay {
                DiagnosticLogOverlay(focusOnDV: viewModel.preferences.focusDiagnosticOverlayOnDV)
            }

            // Floating Skip Intro hint, only while the full controls
            // are hidden. When they open, the skip action becomes a
            // proper focusable button inside TransportBar instead.
            if viewModel.isInsideIntro
                && !viewModel.showControls
                && viewModel.errorMessage == nil
                && !viewModel.showNextEpisodeOverlay {
                introSkipOverlay
            }

            // Next episode overlay
            if viewModel.showNextEpisodeOverlay,
               let next = viewModel.nextEpisode {
                nextEpisodeOverlay(next)
            }

            // Subtitle search overlay (Feature #4). Reaches for the
            // literal player tint so its focused rows fill with the
            // server-configured accent rather than white.
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
                HStack(spacing: 10) {
                    Image(systemName: "forward.end.fill")
                        .font(.body)
                    Text(String(localized: "player.skipIntro", defaultValue: "Skip Intro"))
                        .font(.body)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
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
                .padding(.trailing, 80)
                .padding(.bottom, 80)
            }
        }
        // ignoresSafeArea so the hint stays pinned to the actual screen
        // bottom-right corner. `suppressAVKitChrome` sets AVKit's
        // chrome views to alpha=0 (so the iPhone Control Center +10s
        // handler still wires up via `playbackControlsIncludeTransportBar`
        // without showing duplicate transport bars), but the chrome
        // views still exist in the view tree and AVKit still widens
        // contentOverlayView's bottom safe-area inset to "make room"
        // for them. With the widened inset our `VStack { Spacer() }`
        // layout shifts the hint up by the chrome's nominal height,
        // parking it in the middle of the screen at session start.
        // Ignoring safe-area at the overlay level pins the hint to
        // the true screen bottom regardless of the phantom inset.
        // The chrome is alpha=0 so nothing visual gets occluded.
        .ignoresSafeArea()
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    private func nextEpisodeOverlay(_ episode: JellyfinItem) -> some View {
        // Absolute screen-relative positioning instead of any
        // parent-geometry-dependent layout. `UIScreen.main.bounds`
        // is fixed for the playback session on tvOS (1920x1080 or
        // 3840x2160 depending on Apple TV gen); the card sits at a
        // computed (x, y) center point that doesn't recompute when
        // the SwiftUI parent reflows.
        //
        // Vincent report 2026-05-26 follow-up: the prior
        // `.frame(maxWidth: .infinity, maxHeight: .infinity,
        // alignment: .bottomTrailing)` fix improved things but the
        // card still jumped toward the middle for the last few
        // frames before `playNextEpisode` swaps the player item.
        // Root cause: at end-of-playback `playNextEpisode` calls
        // `player.stop()` + tears down the AVKit chrome before the
        // new session starts, and during that ~100 ms window the
        // SwiftUI parent's frame collapses around AVKit's shrinking
        // contentOverlayView. Any frame-based or alignment-based
        // anchor recomputes against the smaller frame and the card
        // ends up at "bottom-trailing of a near-empty parent" =
        // mid-screen. Absolute `.position(x:, y:)` against the
        // scene's screen bounds removes the dependency entirely.
        // (Scene-derived screen instead of the tvOS-26-deprecated
        // `UIScreen.main`; tvOS has exactly one scene and screen,
        // the 1080p fallback is for the impossible no-scene case.)
        let screen = UIApplication.shared.connectedScenes
            .lazy.compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.size ?? CGSize(width: 1920, height: 1080)
        let cardW: CGFloat = 380
        let cardH: CGFloat = 214
        let marginX: CGFloat = viewModel.showControls ? 60 : 40
        let marginY: CGFloat = viewModel.showControls ? 300 : 40
        return cardBody(for: episode)
            .position(
                x: screen.width - cardW / 2 - marginX,
                y: screen.height - cardH / 2 - marginY
            )
            .ignoresSafeArea()
            // Asymmetric transition: slide in from the right on
            // appear (nice "here's the next episode" entry), only
            // fade out on disappear. The original symmetric
            // `.move(edge: .trailing)` removal composed with the
            // parent reflow at end-of-playback and made the
            // "drifting to middle" symptom visible. Fade-only
            // removal has no spatial component to disrupt.
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            ))
    }

    private func cardBody(for episode: JellyfinItem) -> some View {
        ZStack(alignment: .topLeading) {
            // Backdrop: episode thumbnail, dimmed so text stays
            // legible. Without an explicit frame + clipped() the
            // AsyncImage's intrinsic size leaks into ZStack sizing
            // and a portrait thumbnail (e.g. when only a series
            // poster is available as fallback) blows the card up
            // into a tall portrait.
            if let imageURL = episodeThumbnailURL(for: episode) {
                // AsyncCachedImage, not AsyncImage: the card mounts and
                // unmounts with the overlay, and a raw AsyncImage
                // re-fetched the thumbnail each time, at the worst
                // moment (end of episode, next item prefetching).
                AsyncCachedImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.clear
                }
                .frame(width: 380, height: 214)
                .clipped()
                .opacity(0.4)
            }

            // Foreground text content. .topLeading alignment + Spacer
            // distribute header / title / countdown across the card
            // height instead of bunching them in the centre.
            VStack(alignment: .leading, spacing: 0) {
                // Episodes (series autoplay or an episode shuffle queue)
                // keep "Next Episode"; a movie reached via a shuffle queue
                // shows "Up Next" instead. The S/E label below is naturally
                // hidden for movies (no parent/index numbers).
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
            .frame(width: 380, height: 214, alignment: .topLeading)
        }
        // Fixed 16:9 card. Both the image and the content above use
        // the same explicit 380x214 frame, so the ZStack itself is
        // exactly that size, nothing intrinsic-leaking can stretch
        // it into a portrait.
        .frame(width: 380, height: 214)
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

    private var controlsOverlay: some View {
        // Pin the whole controls layer to the scene's screen bounds, the same
        // fix the next-episode card uses. An audio-track switch reloads AVKit
        // and its container frame transiently collapses; a Spacer/alignment-
        // anchored overlay reflows against the shrunken parent, so the entire
        // controls block jumps up while it is fading out. An absolute
        // screen-sized frame + center position removes the dependency on the
        // churning AVKit parent, the layer stays put through the reload.
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

            // Title (top left). HDR + Speed indicators live in a
            // separate always-visible column so the speed badge can
            // persist after the transport hides.
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
    /// Stack of informational badges in the top-right corner. The
    /// HDR badge follows the transport's visibility (Apple TV's own
    /// player does the same, informational, not action-required),
    /// while the speed badge is persistent whenever the rate isn't
    /// 1.0× so a user who set 1.5× and then hid the transport doesn't
    /// silently keep watching at the wrong speed.
    var topRightInfoColumn: some View {
        VStack {
            HStack(alignment: .top) {
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    if viewModel.showControls && viewModel.videoFormat != .sdr {
                        VideoFormatBadge(format: viewModel.videoFormat)
                    }
                    // Badge whenever the applied rate isn't 1.0x;
                    // keyed on the rate so edits to speedOptions can't
                    // silently break it.
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

/// Top-left diagnostic HUD that mirrors the engine's recent
/// `print(...)` lines into the player UI. Only mounted in DEBUG /
/// TestFlight builds (gated by `LogTap.isDiagnosticBuild`). Lets a
/// beta tester screenshot what the engine reported (DV detection,
/// HDR10+ extraction, format upgrades, etc.) without pairing the
/// Apple TV to a Mac for Console.app.
private struct DiagnosticLogOverlay: View {
    @ObservedObject private var tap = LogTap.shared
    let focusOnDV: Bool

    /// Number of overlay rows rendered at once. 50 lines at the
    /// current 16 pt monospaced row height fills roughly the top
    /// 2/3 of a 1080p screen, which is what we want during
    /// diagnostic-build investigation sessions: enough vertical
    /// real estate to keep the full session preamble (engine
    /// init.mp4 box summary, HLS server setup, asset.load probes)
    /// AND the eventual AVPlayer failure landing on screen
    /// simultaneously. The overlay only renders in
    /// LogTap.isDiagnosticBuild (DEBUG + TestFlight), so the
    /// occlusion never hits an App Store user.
    private let visibleCount = 50

    /// Substring matchers for the DV / HDR focus mode. A line is
    /// retained when it contains ANY of these. Picked so the diagnostic
    /// chain a remote tester would photograph for a support thread
    /// (engine dispatch, HLS routing state, item tracks, audio route,
    /// display criteria, panel mode signaling) stays in frame while
    /// per-segment cache / muxer chatter falls off. The cost of an
    /// over-narrow filter is a missing data point in a screenshot;
    /// the cost of an over-wide filter is the focus being defeated.
    /// This is the conservative middle.
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
            return tap.lines.filter { line in
                Self.focusSubstrings.contains { line.contains($0) }
            }.suffix(visibleCount).map { $0 }
        }
        return Array(tap.lines.suffix(visibleCount))
    }

    var body: some View {
        VStack {
            // Full-width container so long diagnostic lines
            // (per-packet failure dumps, init.mp4 box summaries,
            // FFmpeg packet rescale traces) don't get truncated by
            // the row's lineLimit(1). The previous bounded box
            // truncated DrHurt's seg4 failure right before tb_out,
            // hiding the field we actually needed to read. Side
            // padding (60 left, 80 right) matches the player's
            // safe-area gutters; nothing else uses the top-left
            // quadrant when the overlay is visible.
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
