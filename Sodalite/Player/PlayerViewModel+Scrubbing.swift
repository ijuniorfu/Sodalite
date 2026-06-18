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

    /// The span the scrubber maps `scrubProgress` (0...1) across. For VOD
    /// that is the content duration; for live it is the buffered DVR window
    /// (`liveSeekableRange`). Returns 0 when there is nothing to scrub yet
    /// (live window not accrued), which keeps the scrub entry points gated.
    var scrubReferenceDuration: Double {
        if isLiveSession {
            guard let range = liveSeekableRange,
                  range.upperBound > range.lowerBound else { return 0 }
            return range.upperBound - range.lowerBound
        }
        return effectiveDuration
    }

    /// Minimum scrubbed distance, in seconds away from the live playhead,
    /// that marks a scrub as a deliberate seek rather than the sub-second
    /// touchpad jitter the Siri Remote emits in the moments before a click.
    /// The velocity-gated commit (`scrubCommitMinVelocity` + a translation
    /// reset) keeps that pre-click pan tiny, well under this; a real drag
    /// across the scrubber moves tens of seconds.
    static let deliberateScrubThresholdSeconds: Double = 5

    /// True when the active scrub has moved a deliberate distance from the
    /// live playhead, as opposed to the pre-click touchpad jitter. Used so a
    /// real scrub out of an intro commits to its target instead of being
    /// hijacked into Skip Intro. VOD-only (`effectiveDuration > 0`); live has
    /// no intro segments.
    var scrubMovedMeaningfully: Bool {
        guard isScrubbing else { return false }
        let dur = effectiveDuration
        guard dur > 0 else { return false }
        return abs(Double(scrubProgress - progress)) * dur >= Self.deliberateScrubThresholdSeconds
    }

    func scrub(delta: CGFloat) {
        let dur = scrubReferenceDuration
        guard dur > 0 else { return }

        if !isScrubbing {
            isScrubbing = true
            scrubStartProgress = progress
            showControls = true
            // Seed the preview at scrub start so the card has a frame before
            // the first movement. VOD warms the FrameExtractor; live fetches
            // the first DVR-cache thumbnail via updateLiveScrubPreview.
            if !isLiveSession {
                scrubPreview.prewarm()
            } else {
                updateLiveScrubPreview()
            }
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
        // scrubTime stays VOD-only: the live bar draws its own position label
        // from behindLiveSeconds. The preview IS fed for live via
        // updateLiveScrubPreview (DVR-cache thumbnails from the engine).
        if !isLiveSession {
            scrubTime = formatSeconds(Double(scrubProgress) * dur)
            scrubPreview.update(fraction: scrubProgress, durationSeconds: dur)
        } else { updateLiveScrubPreview() }
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
        // Live takes a dedicated commit: live duration is 0, so the VOD
        // body below would early-return and never seek. commitLiveScrub
        // maps scrubProgress across the moving seekable window instead.
        if isLiveSession { commitLiveScrub(); return }
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

    /// Begin a continuous (hold-to-seek) scrub in `direction` (-1 left, +1
    /// right). Enters scrub mode and advances `scrubProgress` with
    /// acceleration (slow at first, ramping up) until `endContinuousSeek`
    /// is called on release. Like the tap-skip path, the position is a
    /// preview committed only on release.
    func beginContinuousSeek(direction: Int) {
        let dur = scrubReferenceDuration
        guard dur > 0 else { return }

        if !isScrubbing {
            isScrubbing = true
            scrubStartProgress = progress
            scrubProgress = progress
            showControls = true
            // Seed the preview at scrub start (mirrors scrub(delta:)).
            if !isLiveSession {
                scrubPreview.prewarm()
            } else {
                updateLiveScrubPreview()
            }
        }
        controlsTimer?.cancel()
        continuousSeekTask?.cancel()

        let dir = Float(direction < 0 ? -1 : 1)
        continuousSeekTask = Task { @MainActor [weak self] in
            let tick = 0.08
            var held = 0.0
            while !Task.isCancelled {
                guard let self else { return }
                // For live this re-reads the DVR window span each tick (it
                // grows as history accrues); for VOD it is the fixed duration.
                let dur = self.scrubReferenceDuration
                guard dur > 0 else { return }
                // Media-seconds per real second: ramps from 15x, keeping the
                // same acceleration curve, up to a fast 240x ceiling (~8.6s
                // held) so long films can be spooled through quickly.
                let rate = min(15 + held * 26, 240)
                let deltaProgress = dir * Float(rate * tick / dur)
                self.scrubProgress = max(0, min(1, self.scrubProgress + deltaProgress))
                // scrubTime stays VOD-only; the preview IS fed for live
                // via updateLiveScrubPreview (DVR-cache thumbnails).
                if !self.isLiveSession {
                    self.scrubTime = self.formatSeconds(Double(self.scrubProgress) * dur)
                    self.scrubPreview.update(fraction: self.scrubProgress, durationSeconds: dur)
                } else { self.updateLiveScrubPreview() }
                try? await Task.sleep(for: .seconds(tick))
                held += tick
            }
        }
    }

    /// End a continuous spool (press released): stop spooling but KEEP the
    /// scrub preview, exactly like a pan scrub. Playback keeps running; the
    /// user commits the seek with Select (or it auto-cancels on idle).
    func endContinuousSeek() {
        guard continuousSeekTask != nil else { return }
        continuousSeekTask?.cancel()
        continuousSeekTask = nil
        scrubPanEnded()
    }
}
