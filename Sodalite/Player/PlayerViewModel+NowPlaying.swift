import Foundation
import MediaPlayer
import UIKit
import AetherEngine

/// System Now-Playing integration for Sodalite's custom player path
/// (AetherEngine -> AVPlayer -> AVPlayerLayer; not AVPlayerViewController).
///
/// Architecture, after a multi-round bisect on tvOS 26:
///
/// 1. `MPNowPlayingSession` wraps the engine's `AVPlayer` instance and
///    is set to `automaticallyPublishesNowPlayingInfo = true`. The
///    session keeps elapsed time, rate, and play / pause state in sync
///    with the system Now Playing surface; we never write those fields
///    ourselves. Verified: the iPhone Control Center widget shows live
///    progress without any per-tick `MPNowPlayingInfoCenter` writes
///    from us.
///
/// 2. Static metadata (title, artist, album, artwork) is written to
///    `MPNowPlayingInfoCenter.default().nowPlayingInfo` exactly *once*
///    per session, after the artwork fetch resolves. Auto-publish
///    keeps the dynamic keys current via partial updates; our static
///    keys live alongside them undisturbed.
///
/// 3. Multiple writes to `nowPlayingInfo` while the session is active
///    reproducibly tripped `_dispatch_assert_queue_fail` inside
///    MediaPlayer on tvOS 26 (Thread N EXC_BREAKPOINT in
///    `-[MPNowPlayingInfoCenter ...]`). The single-write rule is the
///    one invariant we hold tight on; refresh-on-state-change and
///    delayed-artwork-attach are both banned for that reason.
///
/// 4. `AVPlayerItem.externalMetadata` is intentionally untouched.
///    That surface drives the AVPlayerViewController-style in-player
///    swipe-down info panel, which Sodalite doesn't use; and on the
///    iPhone Control Center / Lock Screen widget side, the iPhone
///    reads from MPNowPlayingInfoCenter directly, not from
///    externalMetadata published by the tvOS app.
extension PlayerViewModel {

    func configureNowPlaying() {
        guard let avPlayer = player.currentAVPlayer else { return }

        let session = MPNowPlayingSession(players: [avPlayer])
        session.automaticallyPublishesNowPlayingInfo = true
        nowPlayingSession = session
        session.becomeActiveIfPossible { _ in /* result not actionable */ }

        bindRemoteCommands(session: session)

        // Single static-metadata write per session. Artwork fetch lands
        // first, then everything goes in one dict assignment.
        Task { [weak self] in await self?.publishStaticInfo() }
    }

    /// No-op. Auto-publish via `MPNowPlayingSession` keeps elapsed /
    /// rate / state current; per-event `nowPlayingInfo` writes from us
    /// re-enter MediaPlayer's internal serial queue and crash.
    func refreshNowPlayingProgress() {
        // Intentionally empty.
    }

    func teardownNowPlaying() {
        let session = nowPlayingSession
        nowPlayingSession = nil

        let center = session?.remoteCommandCenter ?? MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Single static-metadata write

    private func publishStaticInfo() async {
        let title = item.name
        let subtitle = displaySubtitle
        let album = displayAlbum
        let artwork = await fetchArtwork()

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if let album { info[MPMediaItemPropertyAlbumTitle] = album }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
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

    /// Fetch the item's primary image, wrap in an `MPMediaItemArtwork`.
    /// Pre-extracts the `CGImage` so the request handler never reads a
    /// `UIImage` object across threads (CGImage is immutable and safe
    /// to share). LogTap notes record the outcome for debugging.
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

    private func bindRemoteCommands(session: MPNowPlayingSession) {
        let center = session.remoteCommandCenter

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
