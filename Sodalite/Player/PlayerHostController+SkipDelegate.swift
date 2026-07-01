import AVKit
import AetherEngine
import CoreMedia

// MARK: - AVPlayerViewControllerDelegate (skip routing)

/// Skip-navigation delegate plumbing for PlayerHostController.
extension PlayerHostController: AVPlayerViewControllerDelegate {
    // tvOS-only AVPlayerViewControllerDelegate skip/navigation hooks. iOS touch
    // transport (Phase 3) routes seeks directly, not through these delegate calls.
    #if os(tvOS)
    /// Device-verified: iPhone Control Center's 10s skip does NOT dispatch here
    /// (AVKit binds CC's skipForwardCommand to an internal no-op we can't
    /// override). Kept as a fallback for other AVKit skip pathways (Siri Remote
    /// chord, future tvOS); we'd rather seek than no-op.
    ///
    /// `nonisolated`: the AVPlayerViewControllerDelegate requirement is nonisolated, but with Swift 6 +
    /// InferIsolatedConformances this conformance is silently MainActor-isolated, so a plain `func` would inherit
    /// MainActor isolation (no compiler warning) and trip _dispatch_assert_queue_fail if AVKit dispatched the
    /// selector off-main, BEFORE the inner hop runs (same mechanism as the music MPMediaItemArtwork crash). The body
    /// already hops via Task { @MainActor }, so all actor access stays on the actor. Matches the siblings below.
    nonisolated func skipToNextItem(for playerViewController: AVPlayerViewController) {
        LogTap.shared.note("[NowPlaying] delegate skipToNextItem fired (+10s)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let target = self.viewModel.player.currentTime + 10
            await self.viewModel.player.seek(to: target)
        }
    }

    nonisolated func skipToPreviousItem(for playerViewController: AVPlayerViewController) {
        LogTap.shared.note("[NowPlaying] delegate skipToPreviousItem fired (-10s)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let target = max(0, self.viewModel.player.currentTime - 10)
            await self.viewModel.player.seek(to: target)
        }
    }

    /// Apple-documented skip-style navigation hook (forum thread 651497: "the
    /// API that controls skip +/- 10"). Return targetTime to allow the seek,
    /// oldTime to block. Logged to verify whether CC dispatches here.
    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        timeToSeekAfterUserNavigatedFrom oldTime: CMTime,
        to targetTime: CMTime
    ) -> CMTime {
        LogTap.shared.note("[NowPlaying] delegate timeToSeek from=\(oldTime.seconds) to=\(targetTime.seconds)")
        return targetTime
    }

    /// Companion hook: fires when user-initiated navigation resumes playback.
    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willResumePlaybackAfterUserNavigatedFrom oldTime: CMTime,
        to targetTime: CMTime
    ) {
        LogTap.shared.note("[NowPlaying] delegate willResumePlayback from=\(oldTime.seconds) to=\(targetTime.seconds)")
    }
    #endif

    // iOS: PiP coordination. `pipActive` is set synchronously (before PiP dismisses this VC) so
    // viewWillDisappear can skip stopPlayback during the PiP handoff; the engine flag (hopped to MainActor)
    // holds the background keepalive. nonisolated to match the silently-MainActor-isolated conformance.
    #if os(iOS)
    // Keep the player presented when PiP starts (the default dismisses it, so returning from PiP would land
    // on the detail view). Staying presented makes PiP-stop restore the full-screen player automatically.
    nonisolated func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
        false
    }

    // #32: the on-frame overlay isn't in the PiP layer, so PiP needs a real legible track. AVKit wires its
    // legible renderer to the selection that is ACTIVE WHEN the PiP window is established, so select the native
    // WebVTT rendition (matching the user's active subtitle) on WILL-start, before the window forms, not after.
    // Fullscreen keeps the overlay; the rendition is deselected on PiP stop so the two never double up.
    nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        self.pipActive = true
        Task { @MainActor [weak self] in
            self?.viewModel.player.pictureInPictureActive = true
            if PlayerViewModel.nativePiPSubtitleProbe { self?.viewModel.player.setNativeSubtitleForPiP(true) }
        }
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        self.pipActive = false
        Task { @MainActor [weak self] in
            self?.viewModel.player.pictureInPictureActive = false
            if PlayerViewModel.nativePiPSubtitleProbe { self?.viewModel.player.setNativeSubtitleForPiP(false) }
        }
    }
    #endif
}
