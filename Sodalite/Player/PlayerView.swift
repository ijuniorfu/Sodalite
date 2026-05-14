import SwiftUI
import AetherEngine
import AVFoundation
import AVKit

// MARK: - Player Launcher (UIKit modal presentation)

/// Presents PlayerHostController as a UIKit modal (NOT SwiftUI fullScreenCover).
///
/// On tvOS, SwiftUI's fullScreenCover intercepts the Menu button at the
/// presentation level, pressesBegan, .onExitCommand, and gesture recognizers
/// on child VCs never receive it. UIKit modals don't have this problem:
/// UITapGestureRecognizer for .menu on the presented VC's view works.
struct PlayerLauncher: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let item: JellyfinItem?
    let startFromBeginning: Bool
    let playbackService: JellyfinPlaybackServiceProtocol
    let userID: String
    let preferences: PlaybackPreferences
    var cachedPlaybackInfo: PlaybackInfoResponse?
    /// Accent color the overlay should tint with. Nil falls back to the
    /// asset-catalog default. Threaded through by callers because the
    /// WindowGroup `.tint(...)` does not cross into the UIKit modal.
    var tintColor: Color?

    func makeUIViewController(context: Context) -> PlayerLauncherHostVC {
        PlayerLauncherHostVC()
    }

    func updateUIViewController(_ host: PlayerLauncherHostVC, context: Context) {
        if isPresented, let item, host.presentedViewController == nil {
            let vm = PlayerViewModel(
                item: item,
                startFromBeginning: startFromBeginning,
                playbackService: playbackService,
                userID: userID,
                preferences: preferences,
                cachedPlaybackInfo: cachedPlaybackInfo
            )
            let playerVC = PlayerHostController(
                viewModel: vm,
                tintColor: tintColor,
                onDismiss: {
                    host.dismiss(animated: false) {
                        isPresented = false
                    }
                }
            )
            playerVC.modalPresentationStyle = .fullScreen
            host.present(playerVC, animated: false)
        } else if !isPresented, host.presentedViewController != nil {
            host.dismiss(animated: false)
        }
    }
}

/// Invisible host VC for PlayerLauncher. Only purpose: be in the
/// window hierarchy so UIKit present() works. Focus restoration is
/// handled by SwiftUI's @FocusState in the detail views.
final class PlayerLauncherHostVC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }
}

// MARK: - Player View Controller

/// Full-screen video player that handles ALL Siri Remote input.
///
/// Presented via UIKit `present(_:animated:)`, NOT SwiftUI fullScreenCover.
/// This is critical: UIKit modals allow UITapGestureRecognizer to intercept
/// the Menu button, while SwiftUI fullScreenCover steals it at the
/// presentation level.
/// Full-screen video player. Subclasses `AVPlayerViewController` so we
/// inherit Apple's native tvOS player chrome (transport bar, scrubber,
/// audio / subtitle / speed pickers, system info panel) along with the
/// automatic `MPNowPlayingInfoCenter` integration that's gated behind
/// AVKit on tvOS. Custom SwiftUI overlays (next-episode countdown,
/// subtitle rendering for sidecar SRT, diagnostic log, error banner)
/// layer over `contentOverlayView` so they sit between the video and
/// AVKit's chrome.
///
/// Presented via UIKit `present(_:animated:)`, NOT SwiftUI
/// `fullScreenCover`, so the Menu button delivery via
/// `pressesBegan` still works for AVKit's own dismissal handling.
@MainActor
final class PlayerHostController: AVPlayerViewController {
    private let viewModel: PlayerViewModel
    private let tintColor: Color?
    private let onDismiss: () -> Void

    private var hasLaunched = false

    /// True only between `didEnterBackground` and the next
    /// `didBecomeActive`. The Apple TV app switcher (double Home)
    /// fires `willResignActive` but NOT `didEnterBackground`, so it
    /// leaves this false, and we use that signal to skip the
    /// reload-and-pause routine.
    private var wasFullyBackgrounded = false

    /// Child host for the SwiftUI overlays we still own (next-episode
    /// countdown, sidecar SRT subtitle layer, diagnostic log, error
    /// banner). Mounted into `contentOverlayView`.
    private var overlayHost: UIViewController?

    init(
        viewModel: PlayerViewModel,
        tintColor: Color? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.tintColor = tintColor
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // The engine creates the AVPlayer inside `engine.load(url:)`;
        // that finishes asynchronously after `startPlayback` runs.
        // The viewmodel signals us via `onAVPlayerReady` when the
        // player is available, and we hand it to AVKit. Until then
        // AVPlayerViewController shows its native loading spinner.
        viewModel.onAVPlayerReady = { [weak self] avPlayer in
            self?.player = avPlayer
        }

        // End-of-content auto-dismiss: a movie or the last episode of
        // a series rolling its credits leaves a black-screen-with-no-
        // focus state behind. Suppressed in diagnostic builds so the
        // log overlay stays readable after a failed-start session.
        viewModel.onPlaybackReachedEnd = { [weak self] in
            Task { @MainActor in
                guard !LogTap.isDiagnosticBuild else { return }
                self?.dismissPlayer()
            }
        }

        // SwiftUI overlays for the bits AVKit doesn't cover: subtitle
        // rendering for sidecar SRT, the next-episode countdown, the
        // diagnostic log overlay (DEBUG / TestFlight), and the error
        // banner. Mounted into `contentOverlayView` so AVKit's chrome
        // can still draw on top.
        let overlay = PlayerOverlayView(
            viewModel: viewModel,
            onDismiss: { [weak self] in self?.dismissPlayer() }
        )
            .tint(tintColor)
        let hosting = UIHostingController(rootView: overlay)
        hosting.view.backgroundColor = .clear
        hosting.view.isUserInteractionEnabled = false
        addChild(hosting)
        let host = contentOverlayView ?? view!
        host.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: host.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        overlayHost = hosting

        // Background / foreground observers. AVKit pauses on background
        // automatically but the engine's HLS demuxer dies in suspension
        // (VT + AVIO drop), so we reload from the current position when
        // the app comes back.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Kick off playback as the modal *starts* appearing so the
        // engine's load() overlaps with the present + layout sequence.
        guard !hasLaunched else { return }
        hasLaunched = true
        Task { await viewModel.startPlayback() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Only stop playback if the VC is actually being dismissed.
        // Display mode switches (HDR / SDR) briefly trigger
        // viewWillDisappear without actually dismissing; don't kill
        // playback for that.
        guard isBeingDismissed || isMovingFromParent else { return }
        Task { await viewModel.stopPlayback() }
        onDismiss()
    }

    @objc private func appDidEnterBackground() {
        wasFullyBackgrounded = true
    }

    @objc private func appDidBecomeActive() {
        guard viewModel.hasStartedPlaying else { return }
        // App switcher (double Home, swipe between recents) lands here
        // without ever firing didEnterBackground. Skip the reload.
        guard wasFullyBackgrounded else { return }
        wasFullyBackgrounded = false

        // tvOS deactivates the app's AVAudioSession on background.
        // Without explicit re-activation here, the post-reload
        // pause / resume sequence drives an audio renderer with no
        // live session and the user gets stuck on a frozen frame.
        try? AVAudioSession.sharedInstance().setActive(true)

        // VT + AVIO sessions are dead, reload the pipeline at the
        // current position. After the reload, hold the player paused
        // so the user has to press Play deliberately.
        Task { @MainActor in
            try? await viewModel.player.reloadAtCurrentPosition()
            viewModel.player.pause()
        }
    }

    private func dismissPlayer() {
        // Triggers the launcher's onDismiss closure, which calls
        // host.dismiss(...) on PlayerLauncherHostVC and updates the
        // SwiftUI binding. AVKit's own Menu-button dismissal goes
        // through viewWillDisappear instead.
        onDismiss()
    }
}

// MARK: - Overlay View (display-only SwiftUI)

private struct PlayerOverlayView: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            if !viewModel.subtitleCues.isEmpty {
                SubtitleOverlayView(
                    cues: viewModel.subtitleCues,
                    currentTime: viewModel.playbackTime,
                    fontSize: viewModel.preferences.subtitleFontSize,
                    textColor: viewModel.preferences.subtitleColor,
                    background: viewModel.preferences.subtitleBackground,
                    delaySeconds: viewModel.preferences.subtitleDelaySeconds
                )
            }

            if viewModel.isLoading {
                Color.black
                    .ignoresSafeArea()
                    .overlay(ProgressView())
                    .transition(.opacity)
            }

            if let error = viewModel.errorMessage {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .transition(.opacity)
            }

            // Apple's native AVPlayerViewController chrome owns the
            // transport bar now. The `viewModel.showControls` state
            // is still used by the badges below as a visibility hint.

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
                DiagnosticLogOverlay()
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
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.isLoading)
        .animation(.easeInOut(duration: 0.3), value: viewModel.showControls)
        .animation(.easeInOut(duration: 0.3), value: viewModel.showNextEpisodeOverlay)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isInsideIntro)
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
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    private func nextEpisodeOverlay(_ episode: JellyfinItem) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                cardBody(for: episode)
                    .padding(.trailing, viewModel.showControls ? 60 : 40)
                    .padding(.bottom, viewModel.showControls ? 300 : 40)
            }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
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
                AsyncImage(url: imageURL) { image in
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
                Text(String(localized: "player.nextEpisode", defaultValue: "Next Episode"))
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

    /// Build the chapter-thumbnail URL using Jellyfin's
    /// `/Items/{id}/Images/Chapter/{index}` endpoint. Returns nil
    /// when the chapter has no `imageTag`, the dropdown then falls
    /// back to its compact text-only row layout.
    private func chapterThumbnailURL(for index: Int) -> URL? {
        guard let baseURL = viewModel.playbackService.baseURL,
              viewModel.chapters.indices.contains(index),
              let tag = viewModel.chapters[index].imageTag
        else { return nil }
        return URL(string: "\(baseURL)/Items/\(viewModel.item.id)/Images/Chapter/\(index)?tag=\(tag)&maxWidth=480&quality=80")
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
                    // Index 2 is 1.0×, the picker default. Anything
                    // else (0.5/0.75/1.25/1.5/2.0) flips the badge on.
                    if viewModel.activeSpeedIndex != 2 {
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
                let visible = Array(tap.lines.suffix(visibleCount))
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
