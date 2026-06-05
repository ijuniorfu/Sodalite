import Foundation
import AetherEngine

/// Scrubbing for the fullscreen music player, mirroring the video player's
/// model: touchpad-pan / left-right skip / held spool all build a preview
/// position (`scrubProgress`), committed on Select or on release. A held
/// spool accelerates and lands PAUSED (Select resumes), matching the video
/// player exactly.
extension MusicPlaybackCoordinator {

    /// Track duration in seconds (0 when unknown).
    var scrubDuration: Double { duration }

    /// The 0...1 progress the bar should render: the scrub preview while
    /// scrubbing, otherwise the live playback position.
    var displayProgress: Double {
        guard scrubDuration > 0 else { return 0 }
        return isScrubbing
            ? scrubProgress
            : min(max(currentTime / scrubDuration, 0), 1)
    }

    /// The seconds the bar should label (preview while scrubbing, else live).
    var displayTime: Double {
        isScrubbing ? scrubProgress * scrubDuration : currentTime
    }

    private var skipSeconds: Double { 10 }

    /// Discrete left/right skip: enters the scrub preview and nudges the
    /// position by the configured interval (committed on Select).
    func seekSkip(direction: Int) {
        let dur = scrubDuration
        guard dur > 0 else { return }
        beginScrubIfNeeded()
        let delta = Double(direction < 0 ? -1 : 1) * skipSeconds / dur
        scrubProgress = min(max(scrubProgress + delta, 0), 1)
    }

    /// Begin a touchpad-pan scrub (records the starting preview position).
    func scrubBegan() {
        beginScrubIfNeeded()
    }

    /// Set the scrub preview to an absolute 0...1 position (the input view
    /// computes it from the pan translation across the bar).
    func scrub(toFraction fraction: Double) {
        guard isScrubbing else { return }
        scrubProgress = min(max(fraction, 0), 1)
    }

    /// Begin a continuous (hold-to-seek) spool in `direction` (-1 left, +1
    /// right). Accelerates from 15x to 240x, same curve as the video player.
    func beginContinuousSeek(direction: Int) {
        let dur = scrubDuration
        guard dur > 0 else { return }
        beginScrubIfNeeded()
        continuousSeekTask?.cancel()
        let dir = Double(direction < 0 ? -1 : 1)
        continuousSeekTask = Task { @MainActor [weak self] in
            let tick = 0.08
            var held = 0.0
            while !Task.isCancelled {
                guard let self else { return }
                let dur = self.scrubDuration
                guard dur > 0 else { return }
                let rate = min(15 + held * 26, 240)
                self.scrubProgress = min(max(self.scrubProgress + dir * rate * tick / dur, 0), 1)
                try? await Task.sleep(for: .seconds(tick))
                held += tick
            }
        }
    }

    /// End a continuous spool (press released): stop spooling but KEEP the
    /// scrub preview, exactly like a pan scrub. Playback keeps running; the
    /// user commits the seek with Select.
    func endContinuousSeek() {
        continuousSeekTask?.cancel()
        continuousSeekTask = nil
    }

    /// Commit the preview position and seek there. Playback continues as it
    /// was (it was never paused while scrubbing).
    func commitScrub() {
        let dur = scrubDuration
        guard isScrubbing, dur > 0 else {
            isScrubbing = false
            return
        }
        let target = scrubProgress * dur
        isScrubbing = false
        seek(to: target)
    }

    func cancelScrub() {
        continuousSeekTask?.cancel()
        continuousSeekTask = nil
        isScrubbing = false
    }

    private func beginScrubIfNeeded() {
        guard !isScrubbing else { return }
        isScrubbing = true
        scrubProgress = scrubDuration > 0 ? min(max(currentTime / scrubDuration, 0), 1) : 0
    }
}
