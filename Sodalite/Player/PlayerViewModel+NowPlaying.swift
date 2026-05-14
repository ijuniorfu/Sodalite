import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit
import AetherEngine

/// System Now-Playing integration matching Apple's "Becoming a Now
/// Playable App" sample code (the official reference for non-AVKit
/// custom players on tvOS).
///
/// Two non-obvious points that took several iterations to land on:
///
/// 1. Every write to `MPNowPlayingInfoCenter.default().nowPlayingInfo`
///    goes through `DispatchQueue.main.async`, never through
///    `await MainActor.run`. MediaPlayer's internal code asserts the
///    setter is invoked from `dispatch_get_main_queue()`. Swift
///    Concurrency's MainActor executor runs on the main thread but
///    has a different libdispatch identity, so callers nested inside
///    `Task { @MainActor in ... }` or `MainActor.run` trip
///    `_dispatch_assert_queue_fail` inside MediaPlayer's deferred
///    barrier_async chain ~10-15 s into playback.
///
/// 2. Dynamic state (rate, elapsed, duration) is refreshed via a
///    KVO observation on `AVPlayer.rate`, exactly like Apple's
///    `AssetPlayer.swift`. Combine's `publisher(for:options:)` is
///    a thin wrapper over `addObserver(forKeyPath:)`, so this matches
///    Apple's sample without breaking the Combine-based shape of the
///    rest of PlayerViewModel.
extension PlayerViewModel {

    // MARK: - Configure

    func configureNowPlaying() {
        guard let avPlayer = player.currentAVPlayer else { return }

        // Re-activate the audio session at the start of each playback
        // session. Apple's NowPlayable sample does this in
        // handleNowPlayableSessionStart(); MediaPlayer uses the session
        // activation event to identify which AVPlayer is the active
        // Now Playing source. Activating once at engine init and never
        // again may leave MediaPlayer's state machine stale across
        // playbacks.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            LogTap.shared.note("[NowPlaying] AVAudioSession.setActive failed: \(error.localizedDescription)")
        }

        bindRemoteCommands()
        publishStaticMetadata(image: nil)

        // KVO-on-rate via Combine. Re-publishes dynamic info on every
        // rate change (play / pause / seek / buffer-resolve).
        avPlayer.publisher(for: \.rate, options: [.initial])
            .sink { [weak self] _ in
                self?.publishDynamicMetadata()
            }
            .store(in: &cancellables)

        Task { [weak self] in await self?.fetchAndApplyArtwork() }
    }

    /// Kept for the `PlayerViewModel.startObserving` state observer.
    /// The KVO-on-rate path in `configureNowPlaying` already handles
    /// state changes, so this is a no-op.
    func refreshNowPlayingProgress() {
        // Intentionally empty. KVO drives updates.
    }

    func teardownNowPlaying() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false

        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    // MARK: - Writes (all through DispatchQueue.main.async)

    /// Replace title / artist / album / artwork. Preserves dynamic
    /// fields read off the current dict so the dynamic publisher isn't
    /// clobbered when artwork lands.
    private func publishStaticMetadata(image: UIImage?) {
        let title = item.name
        let subtitle = displaySubtitle
        let album = displayAlbum
        let artwork = image.map { img in
            MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        DispatchQueue.main.async {
            let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            var info: [String: Any] = [:]
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
            info[MPNowPlayingInfoPropertyIsLiveStream] = false
            info[MPMediaItemPropertyTitle] = title
            info[MPMediaItemPropertyArtist] = subtitle
            info[MPMediaItemPropertyAlbumTitle] = album
            info[MPMediaItemPropertyArtwork] = artwork
            // Preserve dynamic keys.
            for key in [
                MPMediaItemPropertyPlaybackDuration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime,
                MPNowPlayingInfoPropertyPlaybackRate,
                MPNowPlayingInfoPropertyDefaultPlaybackRate,
            ] where existing[key] != nil {
                info[key] = existing[key]
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// Patch the dynamic block (duration, elapsed, rate). Read-modify-write
    /// so static fields aren't touched. Always reads fresh values off
    /// AVPlayer rather than from PlayerViewModel state to match Apple's
    /// sample exactly.
    private func publishDynamicMetadata() {
        guard let avPlayer = player.currentAVPlayer else { return }
        let rate = avPlayer.rate
        let position: Float = {
            guard let item = avPlayer.currentItem else { return 0 }
            let s = item.currentTime().seconds
            return s.isFinite ? Float(s) : 0
        }()
        let duration: Float = {
            guard let item = avPlayer.currentItem else { return 0 }
            let s = item.duration.seconds
            return s.isFinite ? Float(s) : 0
        }()
        DispatchQueue.main.async {
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            if duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
            info[MPNowPlayingInfoPropertyPlaybackRate] = rate
            info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Float(1.0)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
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

    // MARK: - Artwork fetch

    private func fetchAndApplyArtwork() async {
        guard let url = primaryImageURL() else {
            LogTap.shared.note("[NowPlaying] artwork: no URL for item id=\(item.id) type=\(item.type)")
            return
        }
        LogTap.shared.note("[NowPlaying] artwork: GET \(url.absoluteString)")
        let request = URLRequest(url: url, timeoutInterval: 5.0)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            LogTap.shared.note("[NowPlaying] artwork: status=\(status) bytes=\(data.count)")
            guard let image = UIImage(data: data) else {
                LogTap.shared.note("[NowPlaying] artwork: UIImage decode failed")
                return
            }
            // Hop through DispatchQueue.main.async (not MainActor.run)
            // so the resulting MPNowPlayingInfoCenter write lands on
            // the libdispatch main queue, matching MediaPlayer's
            // internal queue assertions.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { [weak self] in
                    self?.publishStaticMetadata(image: image)
                    continuation.resume()
                }
            }
        } catch {
            LogTap.shared.note("[NowPlaying] artwork: fetch failed: \(error.localizedDescription)")
        }
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

    // MARK: - Remote commands

    private func bindRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.togglePlayPause()
            }
            return .success
        }
    }
}
