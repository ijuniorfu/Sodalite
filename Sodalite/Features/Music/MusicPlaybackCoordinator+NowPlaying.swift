import Foundation
import MediaPlayer
import AVFoundation
import UIKit
import AetherEngine

/// Native system Now-Playing for the music path.
///
/// On tvOS 14+ a bare AVPlayer must own an `MPNowPlayingSession` to stay the active Now-Playing app
/// across a background pause: the SHARED info/command centers aren't reliably bound, so on pause
/// (rate 0) the system drops the app and stops delivering the play button (Apple forums 658311 /
/// 706656). So route EVERYTHING through the engine's per-player session; mixing in the shared
/// singletons produced the earlier half-working state. tvOS infers play/pause from the published
/// `MPNowPlayingInfoPropertyPlaybackRate` (1.0/0.0), kept accurate via the timer.
///
/// The FFmpeg fallback has no AVPlayer/session, so infoCenter/commandCenter resolve to the shared defaults.
/// MPRemoteCommandCenter does NOT guarantee main-thread delivery on tvOS (it dispatches on a background
/// MediaPlayer queue), so each handler returns its status synchronously and hops the actual @MainActor work to
/// the main actor via `Task { @MainActor }`. Assuming main (MainActor.assumeIsolated in the handler body)
/// crashed with dispatch_assert_queue_fail when a command arrived off-main during playback.
extension MusicPlaybackCoordinator {

    /// Info center to write to: the active AVPlayer session's own center, else the shared default (FFmpeg).
    private var infoCenter: MPNowPlayingInfoCenter {
        engine.audioNowPlayingSession?.nowPlayingInfoCenter ?? MPNowPlayingInfoCenter.default()
    }

    /// Command center for transport handlers: the active session's own center, else the shared default.
    private var commandCenter: MPRemoteCommandCenter {
        engine.audioNowPlayingSession?.remoteCommandCenter ?? MPRemoteCommandCenter.shared()
    }

    /// Build + publish the now-playing dictionary, register remote commands (once), kick an async
    /// artwork load. Clears the surface when there is no current item.
    func applyNowPlayingInfo() {
        guard let item = currentItem else {
            clearNowPlayingInfo()
            return
        }

        // Register transport handlers once, on the session's command center (the binding tvOS needs).
        registerRemoteCommandsIfNeeded()

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = item.name
        info[MPMediaItemPropertyArtist] = item.trackArtistLine ?? ""
        info[MPMediaItemPropertyAlbumTitle] = item.albumArtist ?? ""
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        // Preserve already-resolved artwork so a state/duration refresh doesn't flash it away mid-load.
        if let art = cachedArtwork, cachedArtworkItemID == item.id {
            info[MPMediaItemPropertyArtwork] = art
        }
        infoCenter.nowPlayingInfo = info

        // NOTE: deliberately NOT setting MPNowPlayingInfoCenter.playbackState: macOS-only; tvOS
        // third-party apps lack the entitlement so it's silently dropped ("Ignoring setPlaybackState"
        // spam). tvOS reads the PlaybackRate above for play-vs-pause.

        loadArtwork(for: item)
        LogTap.shared.note("[NowPlaying] info set: '\(item.name)' rate=\(isPlaying ? 1 : 0) dur=\(Int(duration))")
    }

    /// Refresh just elapsed + rate on the EXISTING entry (no rebuild / artwork reload / log), on the
    /// timer so the system keeps a live entry: shows the Home overlay promptly (not lagging our last
    /// write), keeps it alive across a pause (stale entries get dropped), and moves the scrubber.
    func refreshNowPlayingElapsed() {
        guard currentItem != nil else { return }
        let center = infoCenter
        guard var info = center.nowPlayingInfo else {
            // No entry yet (first publish): build the full one.
            applyNowPlayingInfo()
            return
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        center.nowPlayingInfo = info
    }

    func clearNowPlayingInfo() {
        infoCenter.nowPlayingInfo = nil
        cachedArtwork = nil
        cachedArtworkItemID = nil
    }

    // MARK: - Artwork

    /// Resolve album-art URL (album image, track primary fallback), load off the main actor, merge
    /// into the live dictionary guarding against a track change mid-load. Caches so refreshes keep it.
    private func loadArtwork(for item: JellyfinItem) {
        let itemID = item.id
        nowPlayingArtworkItemID = itemID

        if cachedArtworkItemID == itemID, cachedArtwork != nil { return }

        guard let url = imageService.musicCoverURL(for: item, maxWidth: 600) else { return }

        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  // Force-decode off-main. A corrupt cover (Jellyfin can serve a truncated embedded image:
                  // "Error -17102 decompressing image -- possibly corrupt") otherwise reaches
                  // MPNowPlayingInfoCenter as a lazily-decoded image and crashes MediaPlayer on its own queue
                  // (dispatch_assert_queue_fail). nil = undecodable, so skip the artwork instead of crashing.
                  let decoded = await image.byPreparingForDisplay() else { return }
            let artwork = MPMediaItemArtwork(boundsSize: decoded.size) { _ in decoded }

            await MainActor.run { [weak self] in
                guard let self else { return }
                // Drop stale artwork if the track changed mid-load.
                guard self.nowPlayingArtworkItemID == itemID else { return }
                self.cachedArtwork = artwork
                self.cachedArtworkItemID = itemID
                let center = self.infoCenter
                guard var info = center.nowPlayingInfo else { return }
                info[MPMediaItemPropertyArtwork] = artwork
                center.nowPlayingInfo = info
            }
        }
    }

    // MARK: - Remote commands

    /// Bind transport handlers to the command center, re-binding whenever the RESOLVED center changes.
    /// The engine routes per codec: AVPlayer-decodable audio -> session center, Opus/Vorbis -> FFmpeg
    /// shared center. A once-only registration bound to whichever was live first, so in a mixed queue
    /// the other path had a target-less center and Control Center / Siri Remote went dead.
    /// Identity-tracked so same-center calls stay no-ops (session is persistent, per-track re-register is churn).
    private func registerRemoteCommandsIfNeeded() {
        let center = commandCenter
        let centerID = ObjectIdentifier(center)
        guard registeredCommandCenterID != centerID else { return }
        registeredCommandCenterID = centerID

        center.playCommand.removeTarget(nil)
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                LogTap.shared.note("[NowPlaying] playCommand fired (isPlaying=\(self.isPlaying), hasItem=\(self.currentItem != nil))")
                self.resume()
            }
            return .success
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                LogTap.shared.note("[NowPlaying] pauseCommand fired (isPlaying=\(self.isPlaying))")
                self.engine.pause()
            }
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                LogTap.shared.note("[NowPlaying] togglePlayPauseCommand fired (isPlaying=\(self.isPlaying))")
                self.togglePlayPause()
            }
            return .success
        }

        center.nextTrackCommand.removeTarget(nil)
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                LogTap.shared.note("[NowPlaying] nextTrackCommand fired (hasNext=\(self.hasNext), index=\(self.currentIndex))")
                self.next()
            }
            return .success
        }

        center.previousTrackCommand.removeTarget(nil)
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                LogTap.shared.note("[NowPlaying] previousTrackCommand fired (hasPrevious=\(self.hasPrevious), index=\(self.currentIndex))")
                self.previous()
            }
            return .success
        }

        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            Task { @MainActor in
                guard let self else { return }
                LogTap.shared.note("[NowPlaying] changePlaybackPositionCommand fired (pos=\(Int(position))s)")
                self.seek(to: position)
            }
            return .success
        }

        LogTap.shared.note("[NowPlaying] shared remote command handlers registered")
    }
}
