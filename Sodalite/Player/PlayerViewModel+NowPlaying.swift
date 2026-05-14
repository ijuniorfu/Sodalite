import Foundation
import MediaPlayer
import UIKit
import AetherEngine

/// System Now-Playing integration via `MPNowPlayingSession` (Apple's
/// recommended path on tvOS 14+ / iOS 13+). The session takes the
/// engine's `AVPlayer` instance and **automatically publishes** elapsed
/// time, playback rate, and play / pause state into the system Now
/// Playing surface (Apple TV Control Center, nearby iPhone Lock-Screen
/// widget, HomePod display, Siri voice control). The host only sets
/// the static metadata (title, artist, album, artwork) once.
///
/// This replaces the earlier manual `MPNowPlayingInfoCenter.nowPlayingInfo`
/// dance, which was crash-prone on tvOS 26: any write while AVPlayer
/// was still in its seek / buffer churn could reenter MediaPlayer's
/// internal serial queue chain and trip a `_dispatch_assert_queue_fail`.
/// With auto-publishing the host writes the info dict once and never
/// again; the dynamic fields (elapsed / rate / state) flow through the
/// session.
extension PlayerViewModel {

    func configureNowPlaying() {
        guard let avPlayer = player.currentAVPlayer else { return }

        let session = MPNowPlayingSession(players: [avPlayer])
        session.automaticallyPublishesNowPlayingInfo = true
        nowPlayingSession = session
        session.becomeActiveIfPossible { _ in /* result not actionable */ }

        // Static metadata: written once. Auto-publish handles the rest.
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = item.name
        if let subtitle = displaySubtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if let album = displayAlbum {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        bindRemoteCommands(session: session)

        // Artwork lands async; one follow-up write that patches the
        // dict with the cover. With the session active, MediaPlayer is
        // in its automatic-publishing mode and the static-field write
        // path is far less reentrant than the per-tick refresh writes
        // that crashed earlier.
        Task { [weak self] in await self?.fetchAndAttachArtwork() }
    }

    /// No-op. Auto-publish via MPNowPlayingSession tracks elapsed / rate
    /// from the AVPlayer; no per-event refresh from the state observer
    /// is needed (or safe).
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

    // MARK: - Remote commands

    /// Bind play / pause / toggle. Even with auto-publish enabled,
    /// transport commands the user issues via HomePod / Siri / nearby
    /// iPhone Remote still need explicit handlers; the session only
    /// auto-publishes outbound state, it doesn't auto-route inbound
    /// commands to a Swift handler. Callbacks defer the engine call
    /// to main via DispatchQueue.main.async (no Task @MainActor: mixing
    /// dispatch hops with actor hops inside MediaPlayer's XPC reply
    /// chain was correlated with the earlier libdispatch assertion).
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

    // MARK: - Artwork

    private func fetchAndAttachArtwork() async {
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
            await applyArtwork(cgImage: cg, size: image.size, scale: image.scale)
        } catch {
            LogTap.shared.note("[NowPlaying] artwork: fetch failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func applyArtwork(cgImage: CGImage, size: CGSize, scale: CGFloat) {
        let artwork = MPMediaItemArtwork(boundsSize: size) { _ in
            UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
