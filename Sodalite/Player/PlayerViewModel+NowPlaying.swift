import Foundation
import MediaPlayer
import UIKit
import AetherEngine

/// System Now-Playing integration. After several bisect rounds against
/// tvOS 26, the only invariant that holds without `_dispatch_assert_queue_fail`
/// inside MediaPlayer is *one write to MPNowPlayingInfoCenter.nowPlayingInfo
/// per session*. Multiple writes — whether from a state observer, a
/// throttled time observer, a separate artwork-attach path, or even
/// just setStaticMetadata followed by setDynamicMetadata in the same
/// runloop tick — reproducibly trip a libdispatch assert inside the
/// MPNowPlayingInfoCenter setter's internal serial queue chain when the
/// AVPlayer is in its initial seek / buffer churn. Swiftfin's per-tick
/// pattern doesn't crash for them but does for us, presumably a
/// timing-profile difference with AetherEngine's HLS loopback path.
///
/// Single-write per session means we can't reflect live state changes
/// (pause stays as rate=1 in the widget, manual scrubs aren't pushed).
/// In exchange the card surfaces with title + series + season-episode
/// + cover + initial position from the resume PTS, the OS extrapolates
/// the timer forward at rate=1, and nothing crashes. That's the deal.
extension PlayerViewModel {

    func configureNowPlaying() {
        bindRemoteCommands()
        Task { [weak self] in await self?.publishOnce() }
    }

    /// No-op. We can't safely refresh after the single write.
    func refreshNowPlayingProgress() {
        // Intentionally empty.
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

    // MARK: - Single-write publish

    private func publishOnce() async {
        let title = item.name
        let subtitle = displaySubtitle
        let album = displayAlbum
        let duration = await MainActor.run { effectiveDuration }
        let resumeSeconds = resumePositionTicks > 0
            ? resumePositionTicks.ticksToSeconds
            : 0.0
        let artwork = await fetchArtwork()

        var info: [String: Any] = [:]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPMediaItemPropertyTitle] = title
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if let album { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Float(duration)
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Float(resumeSeconds)
        info[MPNowPlayingInfoPropertyPlaybackRate] = Float(1.0)
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Float(1.0)
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }

        await MainActor.run {
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

    // MARK: - Artwork

    /// Fetch the item's primary image, decode, and build an
    /// `MPMediaItemArtwork`. Returns nil on any failure; LogTap notes
    /// record the outcome for debugging missing covers from the
    /// Support screen.
    private func fetchArtwork() async -> MPMediaItemArtwork? {
        guard let url = primaryImageURL() else {
            LogTap.shared.note("[NowPlaying] artwork: no URL for item id=\(item.id) type=\(item.type)")
            return nil
        }
        LogTap.shared.note("[NowPlaying] artwork: GET \(url.absoluteString)")
        let request = URLRequest(url: url, timeoutInterval: 5.0)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            LogTap.shared.note("[NowPlaying] artwork: status=\(status) bytes=\(data.count)")
            guard let image = UIImage(data: data) else {
                LogTap.shared.note("[NowPlaying] artwork: UIImage decode failed")
                return nil
            }
            // Pre-extract the CGImage so the request handler doesn't
            // hold a UIImage across MediaPlayer's image-request thread.
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
