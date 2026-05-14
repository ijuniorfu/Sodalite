import Foundation
import Combine
import MediaPlayer
import UIKit
import AetherEngine

/// System Now-Playing integration following the proven Jellyfin/Swiftfin
/// pattern: direct writes to `MPNowPlayingInfoCenter.default().nowPlayingInfo`,
/// no `MPNowPlayingSession`.
///
/// Why not MPNowPlayingSession on tvOS 26: handing the engine's AVPlayer
/// to a session with `automaticallyPublishesNowPlayingInfo=true` while
/// also writing `nowPlayingInfo` manually races against MediaPlayer's
/// internal serial queue and trips `_dispatch_assert_queue_fail`. The
/// straight `MPNowPlayingInfoCenter` path that Swiftfin (and Apple's
/// NowPlayable tutorial code) use accepts per-tick writes without
/// crashing, so we use that.
///
/// Pattern (mirrors `Swiftfin/Shared/Objects/MediaPlayerManager/NowPlayable`):
/// - Static fields (title, artist, album, artwork) are written in
///   `setStaticMetadata`. Called twice per session: once at configure
///   without artwork, once after the async image fetch lands. Reads the
///   current dict first so dynamic fields written by the time-observer
///   loop aren't clobbered.
/// - Dynamic fields (duration, elapsed, rate) are written in
///   `setDynamicMetadata`, driven by:
///     - A `cancellables`-stored throttled Combine subscription on
///       `player.$currentTime` (every 5 s while playing).
///     - One-shot calls from `PlayerViewModel.startObserving`'s
///       `.playing` / `.paused` state transitions (immediate response
///       to user-initiated transport changes).
extension PlayerViewModel {

    func configureNowPlaying() {
        bindRemoteCommands()
        setStaticMetadata(image: nil)
        setDynamicMetadata()
        startNowPlayingTimeObserver()
        Task { [weak self] in await self?.fetchAndApplyArtwork() }
    }

    /// Called from `PlayerViewModel.startObserving` on `.playing` /
    /// `.paused` transitions. Re-publishes the dynamic block so the
    /// widget rate flips immediately when the user pauses or resumes.
    func refreshNowPlayingProgress() {
        setDynamicMetadata()
    }

    func teardownNowPlaying() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Static metadata write

    /// Replace title / artist / album / artwork. Reads the existing
    /// dynamic fields (duration / elapsed / rate) off the current dict
    /// and re-writes them so the second call (after artwork lands)
    /// doesn't reset the widget's progress to zero.
    private func setStaticMetadata(image: UIImage?) {
        let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        var info: [String: Any] = [:]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPMediaItemPropertyTitle] = item.name
        if let subtitle = displaySubtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if let album = displayAlbum {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let image {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        // Preserve dynamic fields the time-observer / state-observer
        // already populated.
        for key in [
            MPMediaItemPropertyPlaybackDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime,
            MPNowPlayingInfoPropertyPlaybackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate,
        ] {
            if let value = existing[key] {
                info[key] = value
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Dynamic metadata write

    /// Patch duration / elapsed / rate into the current dict. Read-modify-write
    /// so the static fields title/artist/album/artwork aren't touched.
    private func setDynamicMetadata() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let duration = effectiveDuration
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Float(duration)
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Float(playbackTime)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Float(1.0) : Float(0.0)
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Float(1.0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Time observer

    /// Subscribe to `player.$currentTime` and re-publish the dynamic
    /// block every 5 s while playback advances. The OS extrapolates the
    /// widget timer between updates from the last published elapsed +
    /// rate, so per-second updates are unnecessary; 5 s is the cadence
    /// Apple's NowPlayable tutorial uses and matches Swiftfin's
    /// behavior.
    private func startNowPlayingTimeObserver() {
        player.$currentTime
            .throttle(for: 5.0, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.setDynamicMetadata()
            }
            .store(in: &cancellables)
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
            await MainActor.run { self.setStaticMetadata(image: image) }
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
