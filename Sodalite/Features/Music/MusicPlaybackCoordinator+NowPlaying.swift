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
/// 706656). The engine owns that session with `automaticallyPublishesNowPlayingInfo` enabled, so the
/// AVPlayer path stages metadata into the item's `nowPlayingInfo` dictionary (via the engine) and the
/// system merges in elapsed/rate/duration. NO manual write to the session's MPNowPlayingInfoCenter:
/// "must not be used" with auto-publishing, and such writes raced MediaPlayer's serial queue on tvOS 26
/// (dispatch_assert_queue_fail). externalMetadata is NOT used here, it is an AVKit property the bare
/// audio AVPlayer (no AVPlayerViewController) never surfaces.
///
/// The FFmpeg fallback has no AVPlayer/session, so infoCenter/commandCenter resolve to the shared defaults,
/// and it writes that shared center directly (no auto-publisher to conflict with).
/// MPRemoteCommandCenter does NOT guarantee main-thread delivery on tvOS (it dispatches on a background
/// MediaPlayer queue), so each handler returns its status synchronously and hops the actual @MainActor work to
/// the main actor via `Task { @MainActor }`. Assuming main (MainActor.assumeIsolated in the handler body)
/// crashed with dispatch_assert_queue_fail when a command arrived off-main during playback.
extension MusicPlaybackCoordinator {

    /// Shared center for the FFmpeg fallback only. The AVPlayer/session path must NOT write a
    /// MPNowPlayingInfoCenter under auto-publishing, so every use of this is gated on `audioNowPlayingSession == nil`.
    private var infoCenter: MPNowPlayingInfoCenter {
        MPNowPlayingInfoCenter.default()
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

        // AVPlayer path: stage metadata into the item's nowPlayingInfo dictionary; the engine's auto-publishing
        // MPNowPlayingSession merges it with the player's elapsed/rate/duration. This is the queue-safe channel.
        // NO manual MPNowPlayingInfoCenter write (which races MediaPlayer's serial queue on tvOS 26 and crashes),
        // and NO externalMetadata (an AVKit/AVPlayerViewController property the bare audio AVPlayer never surfaces).
        if engine.audioNowPlayingSession != nil {
            engine.setAudioNowPlayingInfo(baseNowPlayingDict(for: item))
            loadArtwork(for: item)
            return
        }

        // FFmpeg fallback (Opus/Vorbis: no AVPlayer/session): manual write to the shared center.
        var info = baseNowPlayingDict(for: item)
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        // NOTE: deliberately NOT setting playbackState (macOS-only; tvOS reads PlaybackRate for play/pause).
        infoCenter.nowPlayingInfo = info
        loadArtwork(for: item)
    }

    /// Title/artist/album/mediaType (+ already-resolved artwork) shared by both paths. The session path leaves
    /// elapsed/rate/duration to auto-publishing; the FFmpeg path appends them before writing the shared center.
    private func baseNowPlayingDict(for item: JellyfinItem) -> [String: Any] {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = item.name
        info[MPMediaItemPropertyArtist] = item.trackArtistLine ?? ""
        info[MPMediaItemPropertyAlbumTitle] = item.albumArtist ?? ""
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        // Preserve already-resolved artwork so a state/duration refresh doesn't flash it away mid-load.
        if let art = cachedArtwork, cachedArtworkItemID == item.id {
            info[MPMediaItemPropertyArtwork] = art
        }
        return info
    }

    /// Refresh just elapsed + rate on the EXISTING entry (no rebuild / artwork reload / log), on the
    /// timer so the system keeps a live entry: shows the Home overlay promptly (not lagging our last
    /// write), keeps it alive across a pause (stale entries get dropped), and moves the scrubber.
    func refreshNowPlayingElapsed() {
        // The auto-publishing session derives elapsed/rate from the player; only the FFmpeg fallback needs this.
        guard engine.audioNowPlayingSession == nil, currentItem != nil else { return }
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
        // Clear the AVPlayer path's staged per-item dictionary (no-op if no audio host).
        engine.setAudioNowPlayingInfo([:])
        // The session auto-clears on stop; only the FFmpeg fallback's shared-center entry needs an explicit nil.
        if engine.audioNowPlayingSession == nil {
            infoCenter.nowPlayingInfo = nil
        }
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
                  // "Error -17102 decompressing image -- possibly corrupt") otherwise crashes MediaPlayer when
                  // it decodes the image lazily. nil = undecodable, so skip the artwork instead of crashing.
                  let decoded = await image.byPreparingForDisplay() else { return }

            await MainActor.run { [weak self] in
                guard let self, self.nowPlayingArtworkItemID == itemID else { return }
                let artwork = MPMediaItemArtwork(boundsSize: decoded.size) { _ in decoded }
                self.cachedArtwork = artwork
                self.cachedArtworkItemID = itemID
                if self.engine.audioNowPlayingSession != nil {
                    // AVPlayer path: re-stage the dict WITH artwork for the auto-publishing session.
                    self.engine.setAudioNowPlayingInfo(self.baseNowPlayingDict(for: item))
                } else {
                    // FFmpeg fallback: merge artwork into the shared center.
                    guard var info = self.infoCenter.nowPlayingInfo else { return }
                    info[MPMediaItemPropertyArtwork] = artwork
                    self.infoCenter.nowPlayingInfo = info
                }
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
