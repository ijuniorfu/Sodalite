import Foundation
import MediaPlayer
import UIKit

/// System Now-Playing integration. After multiple bisect rounds the
/// stable shape on tvOS 26 is *one write per session* to
/// `MPNowPlayingInfoCenter.default().nowPlayingInfo`. Three writes
/// (initial info + delayed artwork apply + first-play elapsed refresh)
/// triggered a `_dispatch_assert_queue_fail` inside MediaPlayer's
/// internal serial queue chain ~10-15 s into playback. Collapsing the
/// pipeline to one consolidated write past that.
///
/// Order of operations:
///
/// 1. `bindRemoteCommands()` (synchronous, no info-dict write) so the
///    system marks the app as transport-capable. Without this the Now
///    Playing surface never appears regardless of dictionary contents.
///
/// 2. A single async task fetches artwork (3 s budget; falls back to no
///    cover if the URL or decode fails) and then publishes one info
///    dict containing every field at once. The dict is never written
///    again for the rest of the session. tvOS extrapolates elapsed
///    time forward from the initial value at the published rate=1.0,
///    so the widget timer keeps ticking without any further writes.
///
/// Trade-off: the system Now Playing card appears 0-3 s after playback
/// starts (covering the artwork-fetch budget) rather than instantly,
/// and if the user pauses mid-playback the widget keeps advancing the
/// elapsed counter (the OS doesn't know rate changed). Both are
/// acceptable in exchange for a stable card.
extension PlayerViewModel {

    func configureNowPlaying() {
        bindRemoteCommands()
        Task { [weak self] in await self?.publishConsolidatedNowPlaying() }
    }

    /// Kept as a no-op so the state observer can call it without
    /// touching nowPlayingInfo. Hooking refreshes off Combine sinks
    /// is what tripped the libdispatch assertion on tvOS 26; resist
    /// the urge to add per-event refresh back.
    func refreshNowPlayingProgress() {
        // Intentionally empty. See file-level comment.
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

    // MARK: - Single-write publish

    /// Build the artwork (if any) and the full info dict, then write
    /// once. Runs on a background Task and hops to main only for the
    /// final dictionary assignment.
    private func publishConsolidatedNowPlaying() async {
        let title = item.name
        let subtitle = displaySubtitle
        let album = displayAlbum
        let duration = await MainActor.run { effectiveDuration }
        let resumeSeconds = resumePositionTicks > 0
            ? resumePositionTicks.ticksToSeconds
            : 0.0
        let artwork = await fetchArtwork()

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if let album { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        // Resume-position seconds are the best initial value: the
        // engine already asked AVPlayer to seek there. tvOS extrapolates
        // forward from this at the published rate=1.0, so a tiny
        // seek-latency offset doesn't compound.
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = resumeSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }

        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// Fetch the item's primary image and wrap it in an
    /// `MPMediaItemArtwork`. Returns nil on any failure (no URL,
    /// 3-second timeout, HTTP failure, decode failure). Pre-extracts
    /// the CGImage so the request handler never reads a UIImage object
    /// across threads. LogTap notes record the outcome.
    private func fetchArtwork() async -> MPMediaItemArtwork? {
        guard let url = primaryImageURL() else {
            LogTap.shared.note("[NowPlaying] artwork: no URL for item id=\(item.id) type=\(item.type)")
            return nil
        }
        LogTap.shared.note("[NowPlaying] artwork: GET \(url.absoluteString)")
        let request = URLRequest(url: url, timeoutInterval: 3.0)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            LogTap.shared.note("[NowPlaying] artwork: status=\(status) bytes=\(data.count)")
            guard let image = UIImage(data: data) else {
                LogTap.shared.note("[NowPlaying] artwork: UIImage decode failed")
                return nil
            }
            guard let cg = image.cgImage else {
                LogTap.shared.note("[NowPlaying] artwork: no CGImage on decoded UIImage")
                return nil
            }
            let size = image.size
            let scale = image.scale
            return MPMediaItemArtwork(boundsSize: size) { _ in
                UIImage(cgImage: cg, scale: scale, orientation: .up)
            }
        } catch {
            LogTap.shared.note("[NowPlaying] artwork: fetch failed: \(error.localizedDescription)")
            return nil
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
