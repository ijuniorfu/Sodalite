import Foundation
import AetherEngine

extension PlayerViewModel {

    var effectiveDuration: Double {
        if player.duration > 0 { return player.duration }
        if let ticks = item.runTimeTicks, ticks > 0 {
            return Double(ticks) / 10_000_000
        }
        return 0
    }

    func scrub(delta: CGFloat) {
        let dur = effectiveDuration
        guard dur > 0 else { return }

        if !isScrubbing {
            isScrubbing = true
            scrubStartProgress = progress
            showControls = true
        }
        // Always cancel any pending hide / auto-cancel timer, not just
        // on the first scrub() call. Slow touchpad swipes occasionally
        // make UIPanGestureRecognizer flip to `.ended` momentarily even
        // while the user is still touching, which fires scrubPanEnded
        // and schedules the 5 s auto-hide. When the user keeps panning
        // (a fresh gesture that scrub(delta:) sees) the original guard
        // skipped the cancel because isScrubbing was still true from
        // the previous gesture, so the timer kept running and tore the
        // UI down mid-scrub. Cancelling on every call closes that gap
        // and matches the seekJump path's behaviour.
        controlsTimer?.cancel()

        scrubProgress = max(0, min(1, scrubStartProgress + Float(delta) * 0.3))
        scrubTime = formatSeconds(Double(scrubProgress) * dur)
        scrubPreview.update(fraction: scrubProgress, durationSeconds: dur)
    }

    func scrubPanEnded() {
        guard isScrubbing else { return }
        scrubStartProgress = scrubProgress
        // Auto-cancel on idle. If the user stops scrubbing without
        // pressing Select (commit) or Menu (cancel), treat a few
        // seconds of inactivity as an implicit cancel: the scrub
        // is discarded, playback continues from the position the
        // user was at *before* they started scrubbing, and the
        // controls fade out the same way they do after any other
        // idle. Without this the player UI sits on top of the
        // picture indefinitely after a partial scrub.
        //
        // `scrub(delta:)` cancels controlsTimer the instant the
        // user resumes panning, so the timer only fires on real
        // idle.
        controlsTimer?.cancel()
        controlsTimer = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            isScrubbing = false
            scrubPreview.clear()
            hideControls()
        }
    }

    func commitScrub() {
        let dur = effectiveDuration
        guard isScrubbing, dur > 0 else {
            isScrubbing = false
            return
        }
        let targetTime = Double(scrubProgress) * dur
        // Set progress to scrub position BEFORE clearing isScrubbing.
        // Without this, displayedProgress snaps from scrubProgress back
        // to the old progress value for a brief moment before the seek
        // completes and Combine updates it.
        progress = scrubProgress
        isScrubbing = false
        scrubPreview.clear()
        Task {
            await player.seek(to: targetTime)
            reportProgressIfNeeded()
            scheduleControlsHide()
        }
    }

    func cancelScrub() {
        isScrubbing = false
        scrubPreview.clear()
        scheduleControlsHide()
    }
}
