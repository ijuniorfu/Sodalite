import Foundation
import MediaPlayer
import AVFoundation
import UIKit
import AetherEngine

/// Native system Now-Playing for the music path.
///
/// On tvOS 14+ a bare AVPlayer must own an `MPNowPlayingSession` to stay the
/// active Now-Playing app across a background pause: the SHARED
/// `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` are not reliably bound
/// to the player, so when audio output stops (pause -> rate 0) the system
/// drops the app and the play button stops being delivered (Apple forums
/// 658311 / 706656). So we route EVERYTHING through the engine's per-player
/// session: metadata to `session.nowPlayingInfoCenter`, transport handlers on
/// `session.remoteCommandCenter`. Mixing in the shared singletons is exactly
/// what produced the earlier half-working state. tvOS infers play/pause from
/// the published `MPNowPlayingInfoPropertyPlaybackRate` (1.0 playing / 0.0
/// paused); we keep it accurate and refresh it on a timer.
///
/// The FFmpeg fallback path has no AVPlayer/session, so it falls back to the
/// shared singletons (`infoCenter` / `commandCenter` resolve to the defaults).
///
/// Remote command handlers are delivered on the main thread on tvOS. The
/// coordinator is `@MainActor`, so each handler reads/writes coordinator
/// state inside `MainActor.assumeIsolated`.
extension MusicPlaybackCoordinator {

    /// The Now-Playing info center to write to: the active AVPlayer session's
    /// own center when that path is live, else the shared default (FFmpeg).
    private var infoCenter: MPNowPlayingInfoCenter {
        engine.audioNowPlayingSession?.nowPlayingInfoCenter ?? MPNowPlayingInfoCenter.default()
    }

    /// The command center to register transport handlers on: the active
    /// AVPlayer session's own center when live, else the shared default.
    private var commandCenter: MPRemoteCommandCenter {
        engine.audioNowPlayingSession?.remoteCommandCenter ?? MPRemoteCommandCenter.shared()
    }

    /// Build and publish the now-playing dictionary for the current track,
    /// register the remote commands (once), then kick an async artwork load.
    /// Clears the surface when there is no current item.
    func applyNowPlayingInfo() {
        guard let item = currentItem else {
            clearNowPlayingInfo()
            return
        }

        // Register the transport handlers once, on the session's command
        // center (the binding tvOS needs to keep delivering commands).
        registerRemoteCommandsIfNeeded()

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = item.name
        info[MPMediaItemPropertyArtist] = item.trackArtistLine ?? ""
        info[MPMediaItemPropertyAlbumTitle] = item.albumArtist ?? ""
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        // Preserve any artwork already resolved for this track so a state /
        // duration refresh does not flash it away while a fresh load runs.
        if let art = cachedArtwork, cachedArtworkItemID == item.id {
            info[MPMediaItemPropertyArtwork] = art
        }
        infoCenter.nowPlayingInfo = info

        // NOTE: deliberately NOT setting MPNowPlayingInfoCenter.playbackState.
        // It is a macOS-only mechanism; on tvOS third-party apps lack the
        // private set-playback-state entitlement so it is silently dropped
        // (the "Ignoring setPlaybackState" log spam). tvOS reads the
        // PlaybackRate above to know play-vs-pause.

        loadArtwork(for: item)
        LogTap.shared.note("[NowPlaying] info set: '\(item.name)' rate=\(isPlaying ? 1 : 0) dur=\(Int(duration))")
    }

    /// Lightweight refresh of just the elapsed time + rate on the EXISTING
    /// now-playing entry, without rebuilding the whole dictionary, reloading
    /// artwork, or logging. Driven by a periodic timer so the system keeps a
    /// fresh, live entry: tvOS shows the Home Now-Playing overlay promptly
    /// (instead of lagging behind our last discrete write) and keeps it alive
    /// across a pause (a stale entry gets dropped, hiding the overlay and the
    /// remote play route). Also keeps the system progress/scrubber moving.
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

    /// Tear down the system now-playing surface.
    func clearNowPlayingInfo() {
        infoCenter.nowPlayingInfo = nil
        cachedArtwork = nil
        cachedArtworkItemID = nil
    }

    // MARK: - Artwork

    /// Resolve an album-art URL (album image preferred, track primary as
    /// fallback) and load it off the main actor, then merge the artwork
    /// into the live now-playing dictionary, guarding against a track
    /// change while the load was in flight. Caches the resolved artwork so
    /// subsequent state/duration refreshes keep showing it.
    private func loadArtwork(for item: JellyfinItem) {
        let itemID = item.id
        nowPlayingArtworkItemID = itemID

        // Already resolved for this track, nothing to fetch.
        if cachedArtworkItemID == itemID, cachedArtwork != nil { return }

        guard let url = imageService.musicCoverURL(for: item, maxWidth: 600) else { return }

        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

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

    /// Bind transport handlers to the session's command center exactly once.
    /// Registering on the session center (not the shared one) is what keeps
    /// commands flowing across a background pause. Done once: the session is
    /// persistent for the engine's lifetime, so re-registering per track is
    /// unnecessary churn.
    private func registerRemoteCommandsIfNeeded() {
        guard !didRegisterRemoteCommands else { return }
        didRegisterRemoteCommands = true
        let center = commandCenter

        center.playCommand.removeTarget(nil)
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            return MainActor.assumeIsolated {
                guard let self else { return .commandFailed }
                LogTap.shared.note("[NowPlaying] playCommand fired (isPlaying=\(self.isPlaying), hasItem=\(self.currentItem != nil))")
                self.resume()
                return .success
            }
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            return MainActor.assumeIsolated {
                guard let self else { return .commandFailed }
                LogTap.shared.note("[NowPlaying] pauseCommand fired (isPlaying=\(self.isPlaying))")
                self.engine.pause()
                return .success
            }
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            return MainActor.assumeIsolated {
                guard let self else { return .commandFailed }
                LogTap.shared.note("[NowPlaying] togglePlayPauseCommand fired (isPlaying=\(self.isPlaying))")
                self.togglePlayPause()
                return .success
            }
        }

        center.nextTrackCommand.removeTarget(nil)
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            return MainActor.assumeIsolated {
                guard let self else { return .commandFailed }
                LogTap.shared.note("[NowPlaying] nextTrackCommand fired (hasNext=\(self.hasNext), index=\(self.currentIndex))")
                self.next()
                return .success
            }
        }

        center.previousTrackCommand.removeTarget(nil)
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            return MainActor.assumeIsolated {
                guard let self else { return .commandFailed }
                LogTap.shared.note("[NowPlaying] previousTrackCommand fired (hasPrevious=\(self.hasPrevious), index=\(self.currentIndex))")
                self.previous()
                return .success
            }
        }

        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            return MainActor.assumeIsolated {
                guard let self else { return .commandFailed }
                LogTap.shared.note("[NowPlaying] changePlaybackPositionCommand fired (pos=\(Int(position))s)")
                self.seek(to: position)
                return .success
            }
        }

        LogTap.shared.note("[NowPlaying] shared remote command handlers registered")
    }
}
