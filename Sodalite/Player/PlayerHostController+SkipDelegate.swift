import AVKit
import AetherEngine
import CoreMedia

// MARK: - AVPlayerViewControllerDelegate (skip routing)

/// Skip-navigation delegate plumbing for PlayerHostController.
///
/// Lives in its own file so PlayerHostController.swift stays focused
/// on the AVPlayerViewController host class. None of these callbacks
/// touch private state on the host — only `viewModel`, which is
/// promoted to file-internal access for this purpose.
extension PlayerHostController: AVPlayerViewControllerDelegate {
    /// `skippingBehavior = .skipItem` was the last documented Apple-
    /// API attempt to route iPhone Control Center's 10s skip buttons
    /// into our code. Verified on device: CC press does NOT dispatch
    /// here. AVKit's internal Now Playing session enables the
    /// skipForwardCommand on its own per-session command center
    /// (which is why CC shows the buttons) but binds them to an
    /// internal no-op handler we have no documented way to override.
    /// Kept as the safe fallback in case other AVKit pathways (Siri
    /// Remote skipItem chord, future tvOS evolution) actually fire
    /// here — we'd rather seek than no-op.
    func skipToNextItem(for playerViewController: AVPlayerViewController) {
        LogTap.shared.note("[NowPlaying] delegate skipToNextItem fired (+10s)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let target = self.viewModel.player.currentTime + 10
            await self.viewModel.player.seek(to: target)
        }
    }

    func skipToPreviousItem(for playerViewController: AVPlayerViewController) {
        LogTap.shared.note("[NowPlaying] delegate skipToPreviousItem fired (-10s)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let target = max(0, self.viewModel.player.currentTime - 10)
            await self.viewModel.player.seek(to: target)
        }
    }

    /// The Apple-documented "skip-style navigation" delegate hook.
    /// Forum thread 651497 (Apple Media Engineer answering): this is
    /// "the API that controls skip +/- 10". Description suggests it
    /// fires for any user-initiated skip navigation — possibly
    /// including iPhone Control Center. Return value modifies WHERE
    /// the seek lands (return targetTime unmodified to let AVKit's
    /// default seek go through; return oldTime to block).
    /// Logging both args so we can verify CC dispatches here.
    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        timeToSeekAfterUserNavigatedFrom oldTime: CMTime,
        to targetTime: CMTime
    ) -> CMTime {
        LogTap.shared.note("[NowPlaying] delegate timeToSeek from=\(oldTime.seconds) to=\(targetTime.seconds)")
        return targetTime
    }

    /// Companion notification hook: fires when the user-initiated
    /// navigation resumes playback. Combined with timeToSeek above
    /// they document AVKit's skip-navigation pipeline.
    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willResumePlaybackAfterUserNavigatedFrom oldTime: CMTime,
        to targetTime: CMTime
    ) {
        LogTap.shared.note("[NowPlaying] delegate willResumePlayback from=\(oldTime.seconds) to=\(targetTime.seconds)")
    }
}
