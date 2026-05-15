import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit
import AetherEngine

/// System Now Playing wiring, Swiftfin-pattern.
///
/// Architecture: manual `MPNowPlayingInfoCenter.nowPlayingInfo` writes
/// for title / description / artwork / duration / elapsed / rate,
/// plus explicit targets on `MPRemoteCommandCenter.shared()` for
/// play, pause, scrub, and 10s skip-forward / skip-backward. Mirrors
/// Swiftfin's `NowPlayableObserver` 1:1.
///
/// This pattern was unsafe before AetherEngine's loopback was
/// rewritten in BSD sockets (engine commit 962292d): manual writes
/// from outside AVKit reproducibly tripped `_dispatch_assert_queue_fail`
/// deep inside MediaPlayer whenever AVPlayer was reading from the
/// previous `NWConnection`-backed loopback server. With the
/// loopback rewritten on POSIX sockets the race window is gone and
/// the documented Apple-pattern works the same way it does in
/// Swiftfin (which avoids the issue entirely by using direct HTTPS
/// to Jellyfin instead of a loopback).
///
/// AVPlayerViewController is still the playback host so we keep
/// AirPods auto-detection, Enhance Dialogue, Reduce Loud Sounds,
/// and synchronized Atmos. The visible chrome is suppressed via the
/// `playbackControlsIncludeTransportBar = false` /
/// `playbackControlsIncludeInfoViews = false` subset flags.
///
/// Flow:
///   1. `bindRemoteCommands` (pre-load): wire all the
///      `MPRemoteCommandCenter.shared()` targets to engine methods.
///      Stays bound for the lifetime of the playback session.
///   2. `publishStaticNowPlayingInfo(artworkData:)` (post-load,
///      called twice — once with nil artwork, once with the JPEG
///      after the async fetch resolves): title / description /
///      artwork / duration. Writes a fresh dict each time.
///   3. `publishDynamicNowPlayingInfo()` (post-load, throttled to
///      1Hz via Combine sub on engine.$currentTime): merges
///      elapsed / rate / duration into the existing dict.
///   4. `teardownNowPlaying` (stopPlayback): remove targets, clear
///      nowPlayingInfo.
extension PlayerViewModel {

    // MARK: - Lifecycle

    /// One-shot entry point. Call once per startPlayback session.
    /// Restartable across audio-track switch (engine.selectAudioTrack
    /// reuses the same PlayerViewModel and re-fires currentAVPlayer
    /// — we just re-publish dynamic info; static info doesn't change).
    func startNowPlaying() {
        bindRemoteCommands()
        publishStaticNowPlayingInfo(artworkData: nil)

        // Subscribe to engine state changes for dynamic
        // (elapsed/rate) republish. Throttled at 1Hz: the engine
        // emits currentTime every 100ms which would be overkill
        // and could starve the dispatch queue.
        nowPlayingCancellables.removeAll()
        player.$currentTime
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.publishDynamicNowPlayingInfo()
            }
            .store(in: &nowPlayingCancellables)
        // Rate changes (play/pause/seek) should land immediately, not
        // wait for the next 1Hz tick.
        player.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.publishDynamicNowPlayingInfo()
            }
            .store(in: &nowPlayingCancellables)
    }

    func teardownNowPlaying() {
        nowPlayingCancellables.removeAll()
        unbindRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Static info publish

    /// Write title / description / artwork / duration to
    /// `MPNowPlayingInfoCenter`. Called once with nil artwork
    /// pre-cover-fetch, then again with the JPEG once the async
    /// fetch lands. Dynamic fields (elapsed/rate) are added by
    /// `publishDynamicNowPlayingInfo` and survive across static
    /// re-publishes via read-modify-write.
    func publishStaticNowPlayingInfo(artworkData: Data?) {
        let title = item.name
        let subtitle = displaySubtitle
        let album = displayAlbum
        let duration = effectiveDuration

        var artwork: MPMediaItemArtwork?
        if let data = artworkData, let image = UIImage(data: data) {
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        var info: [String: Any] = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        info[MPMediaItemPropertyTitle] = title
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if let album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Dynamic info publish

    /// Update elapsed / rate / duration. Idempotent. Called via
    /// throttled Combine sink on engine.$currentTime + engine.$state.
    func publishDynamicNowPlayingInfo() {
        var info: [String: Any] = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        let dur = effectiveDuration
        if dur > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = dur
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Artwork pre-fetch

    /// Async-fetch the primary image and re-publish the static info
    /// with the artwork attached. Failures leave the title-only
    /// metadata in place.
    func refreshNowPlayingArtwork() async {
        guard let url = primaryImageURL() else {
            LogTap.shared.note("[NowPlaying] artwork: no URL for item id=\(item.id)")
            return
        }
        LogTap.shared.note("[NowPlaying] artwork: GET \(url.absoluteString)")
        let request = URLRequest(url: url, timeoutInterval: 5.0)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            LogTap.shared.note("[NowPlaying] artwork: status=\(status) bytes=\(data.count)")
            guard let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.85) else {
                LogTap.shared.note("[NowPlaying] artwork: decode/re-encode failed")
                return
            }
            await MainActor.run {
                self.publishStaticNowPlayingInfo(artworkData: jpeg)
            }
        } catch {
            LogTap.shared.note("[NowPlaying] artwork: fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Remote commands

    private func bindRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.togglePlayPause()
            }
            return .success
        }

        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.player.seek(to: event.positionTime)
            }
            return .success
        }

        center.skipForwardCommand.removeTarget(nil)
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval: Double
            if let skipEvent = event as? MPSkipIntervalCommandEvent {
                interval = skipEvent.interval > 0 ? skipEvent.interval : 10
            } else {
                interval = 10
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.player.seek(to: self.player.currentTime + interval)
            }
            return .success
        }

        center.skipBackwardCommand.removeTarget(nil)
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval: Double
            if let skipEvent = event as? MPSkipIntervalCommandEvent {
                interval = skipEvent.interval > 0 ? skipEvent.interval : 10
            } else {
                interval = 10
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.player.seek(to: max(0, self.player.currentTime - interval))
            }
            return .success
        }
    }

    private func unbindRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    // MARK: - Display strings

    private var displaySubtitle: String? {
        if item.type == .episode, let series = item.seriesName, !series.isEmpty {
            return series
        }
        if let year = item.productionYear {
            return String(year)
        }
        return nil
    }

    private var displayAlbum: String? {
        guard item.type == .episode else { return nil }
        var parts: [String] = []
        if let season = item.parentIndexNumber {
            parts.append("Season \(season)")
        }
        if let ep = item.indexNumber {
            parts.append("Episode \(ep)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func primaryImageURL() -> URL? {
        guard let base = playbackService.baseURL?.absoluteString else { return nil }
        if let tag = item.imageTags?.primary {
            return URL(string: "\(base)/Items/\(item.id)/Images/Primary?tag=\(tag)&maxWidth=800&quality=85")
        }
        if let tags = item.backdropImageTags, let tag = tags.first {
            return URL(string: "\(base)/Items/\(item.id)/Images/Backdrop?tag=\(tag)&maxWidth=800&quality=85")
        }
        if let tags = item.parentBackdropImageTags, let tag = tags.first, let seriesId = item.seriesId {
            return URL(string: "\(base)/Items/\(seriesId)/Images/Backdrop?tag=\(tag)&maxWidth=800&quality=85")
        }
        return nil
    }
}
