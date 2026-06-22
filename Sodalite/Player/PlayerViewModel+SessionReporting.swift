import Foundation
import AetherEngine

extension PlayerViewModel {

    /// Position in Jellyfin ticks from playbackTime (survives player.stop(),
    /// unlike player.currentTime). Falls back to resumePositionTicks only when
    /// playbackTime == 0; NOT max(ticks, resumePositionTicks), which clamped a
    /// rewind past the resume point back up so Jellyfin never recorded it.
    var currentPositionTicks: Int64 {
        let ticks = Int64(playbackTime * 10_000_000)
        return ticks > 0 ? ticks : resumePositionTicks
    }

    func reportStart() async {
        guard !hasReportedStart else { return }
        hasReportedStart = true
        let ticks = currentPositionTicks
        let report = PlaybackStartReport(
            itemId: item.id,
            mediaSourceId: mediaSourceID,
            playSessionId: playSessionID,
            positionTicks: ticks,
            canSeek: true,
            playMethod: activePlayMethod.rawValue,
            audioStreamIndex: nil,
            subtitleStreamIndex: nil
        )
        do {
            try await playbackService.reportPlaybackStart(report)
        } catch {
            #if DEBUG
            print("[SessionReport] Start FAILED: \(error)")
            #endif
        }
    }

    func reportProgress() async {
        let ticks = currentPositionTicks
        guard ticks > 0 else { return } // Don't report position 0
        let report = PlaybackProgressReport(
            itemId: item.id,
            mediaSourceId: mediaSourceID,
            playSessionId: playSessionID,
            positionTicks: ticks,
            isPaused: !isPlaying,
            canSeek: true,
            playMethod: activePlayMethod.rawValue,
            audioStreamIndex: nil,
            subtitleStreamIndex: nil
        )
        do {
            try await playbackService.reportPlaybackProgress(report)
        } catch {
            #if DEBUG
            print("[SessionReport] Progress FAILED: \(error)")
            #endif
        }
    }

    func reportStop(positionTicks: Int64? = nil, liveStreamID: String? = nil) async {
        // positionTicks override lets stopPlayback() capture position BEFORE
        // killing the engine (stop audio first, no trailing buffer on dismiss).
        // liveStreamID closes a dead tuner on retune (belt-and-braces with
        // the explicit closeLiveStream).
        let ticks = positionTicks ?? currentPositionTicks
        let report = PlaybackStopReport(
            itemId: item.id,
            mediaSourceId: mediaSourceID,
            playSessionId: playSessionID,
            positionTicks: ticks,
            liveStreamId: liveStreamID
        )
        do {
            try await playbackService.reportPlaybackStopped(report)
            // Payload lets detail/Home patch this item's resume position in
            // place, race-free, instead of re-fetching (issue #24).
            NotificationCenter.default.post(
                name: .playbackProgressDidChange,
                object: nil,
                userInfo: [
                    PlaybackProgressKey.itemID: item.id,
                    PlaybackProgressKey.positionTicks: ticks
                ]
            )
        } catch {
            #if DEBUG
            print("[SessionReport] Stop FAILED: \(error)")
            #endif
        }
    }

    func startProgressReporting() {
        progressTimer?.cancel()
        progressTimer = Task {
            // Wait for the first time update, then report so short views track.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await reportProgress()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await reportProgress()
            }
        }
    }

    /// Report progress on pause/seek. Task handle is tracked so stopPlayback()
    /// can cancel an orphaned report after dismiss on a slow CDN.
    func reportProgressIfNeeded() {
        progressReportOnDemandTask?.cancel()
        progressReportOnDemandTask = Task { @MainActor [weak self] in
            await self?.reportProgress()
        }
    }

    func stopProgressReporting() {
        progressTimer?.cancel()
        progressTimer = nil
    }
}
