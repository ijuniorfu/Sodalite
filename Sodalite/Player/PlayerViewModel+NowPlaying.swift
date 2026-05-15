import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit
import AetherEngine

/// System Now-Playing integration following the KSPlayer pattern —
/// a working tvOS custom player (no AVPlayerViewController in sight)
/// that does its own writes to `MPNowPlayingInfoCenter`. The crucial
/// detail their code exposes that ours missed across six iterations:
///
///   **Use subscript patches (`nowPlayingInfo?[key] = value`),
///   not full-dict replacement (`nowPlayingInfo = info`).**
///
/// Full-dict replace was what reproducibly tripped the
/// `_dispatch_assert_queue_fail` inside MediaPlayer on tvOS 26 a
/// few seconds into playback. Apple's own NowPlayable sample uses
/// full-dict replace too, but Apple's sample plays simple file URLs;
/// our HLS-loopback AVPlayer setup hits an internal queue race that
/// the sample doesn't. KSPlayer's per-key patches avoid the route
/// that races.
///
/// Wiring:
///   1. `configureNowPlaying` (post engine.load): seed the initial
///      static fields, bind remote commands, start an
///      `AVPlayer.addPeriodicTimeObserver` that patches elapsed time
///      and rate at 1 Hz.
///   2. `refreshNowPlayingProgress` (state observer hook): subscript-
///      patch the rate / elapsed fields on play/pause/seek transitions
///      so the widget reflects state changes immediately rather than
///      waiting for the next time-observer tick.
///   3. Async artwork fetch: subscript-patches the artwork key when
///      the JPEG bytes land.
///   4. `teardownNowPlaying`: full-replace with `nil` is the only
///      safe full-replace (MediaPlayer accepts nil reset).
extension PlayerViewModel {

    func configureNowPlaying() {
        bindRemoteCommands()
        publishStaticInitialInfo()
        // Artwork apply was the empirical crash trigger — happened
        // 1-3 s into playback when AVPlayer was still in its track-load
        // / segment-prefetch phase. Delay 30 s so the AVPlayer / HLS
        // pipeline is fully settled before we touch nowPlayingInfo
        // again. If the crash still fires, it's the write itself, not
        // the timing.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            await self?.fetchAndApplyArtwork()
        }
    }

    func refreshNowPlayingProgress() {
        // Empirically the per-event nowPlayingInfo patches kept tripping
        // the libdispatch race in MediaPlayer regardless of pattern
        // (full-replace, subscript, periodic, on-transition). Disabled
        // until we have a way around the underlying conflict —
        // probably needs the engine to stop using HLS-loopback or for
        // us to migrate back to AVPlayerViewController.
    }

    func teardownNowPlaying() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        // Full nil-replace is the only "safe" full-replace MediaPlayer
        // accepts; the libdispatch race only manifests on non-nil
        // replaces while AVPlayer is in its setup phase.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Initial static dictionary

    /// One-time seed of the static fields. From here on every update
    /// goes through subscript patches. This first write is the only
    /// "full" assignment we do and it happens BEFORE AVPlayer settles
    /// — a brief window where MediaPlayer's internal state isn't
    /// mid-chain on something else.
    private func publishStaticInitialInfo() {
        let duration = effectiveDuration
        var info: [String: Any] = [:]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        info[MPMediaItemPropertyTitle] = item.name
        if let subtitle = displaySubtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if let album = displayAlbum {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        let resumeSec = resumePositionTicks > 0 ? resumePositionTicks.ticksToSeconds : 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = resumeSec
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Dynamic patches

    /// Subscript-patch rate / elapsed / duration. Called on state
    /// transitions and from the periodic time observer. Reads CURRENT
    /// state at call time and patches individual keys without rebuilding
    /// the dictionary.
    private func patchDynamicNowPlaying() {
        guard MPNowPlayingInfoCenter.default().nowPlayingInfo != nil else { return }
        let elapsed = playbackTime
        let rate = isPlaying ? 1.0 : 0.0
        let duration = effectiveDuration
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = rate
        if duration > 0 {
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] = duration
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

    // MARK: - Artwork

    /// Async fetch + subscript-patch the artwork key. Uses CGImage in
    /// the request handler closure (immutable, safe to retain across
    /// MediaPlayer's image-request thread).
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
            guard let cg = image.cgImage else {
                LogTap.shared.note("[NowPlaying] artwork: no CGImage on decoded UIImage")
                return
            }
            let size = image.size
            let scale = image.scale
            let artwork = MPMediaItemArtwork(boundsSize: size) { _ in
                UIImage(cgImage: cg, scale: scale, orientation: .up)
            }
            await MainActor.run {
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
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
