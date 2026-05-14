import Foundation
import MediaPlayer
import UIKit

/// System Now-Playing integration. Bisect step 2: the minimum-data-only
/// version showed no crash but tvOS didn't surface the Now Playing card,
/// because the system gates the card on the app declaring itself
/// transport-capable via at least one enabled `MPRemoteCommandCenter`
/// command. This version adds the three transport commands back in.
///
/// Still deliberately disabled to keep the surface small while we
/// confirm stability on tvOS 26:
///   - No mid-session refresh of elapsed / rate (`refreshNowPlayingProgress`
///     is a no-op). Initial values are written once at configure; the
///     system extrapolates elapsed time from there.
///   - No artwork. The earlier `MPMediaItemArtwork(boundsSize:requestHandler:)`
///     attach correlated with one of the crashes; reintroduce it after
///     this version proves stable.
extension PlayerViewModel {

    func configureNowPlaying() {
        // Order matters on tvOS: bind remote commands first so the
        // system sees the app as transport-capable before we publish
        // the info dictionary.
        bindRemoteCommands()

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = item.name
        if let subtitle = displaySubtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if let album = displayAlbum {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        let duration = effectiveDuration
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue

        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        Task { [weak self] in await self?.loadAndAttachArtwork() }
    }

    /// No-op for now. Kept as the entry point the state observer calls
    /// so a later commit can wire periodic / event-driven refresh back
    /// in without touching PlayerViewModel.swift again.
    func refreshNowPlayingProgress() {
        // Intentionally empty during the tvOS 26 crash bisect.
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

    /// Bind play / pause / toggle to engine transport. Callbacks return
    /// `.success` synchronously and hop the actual engine call to main
    /// via `DispatchQueue.main.async`. No `Task { @MainActor in }` here:
    /// mixing dispatch hops and actor hops inside MediaPlayer's XPC
    /// reply chain was correlated with the earlier libdispatch
    /// assertion.
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

    /// Fetch the item's primary image, decode to UIImage, attach as
    /// `MPMediaItemArtwork`. Silent on failure; LogTap notes record
    /// outcomes so a missing cover can be debugged from the Support
    /// screen's log buffer.
    private func loadAndAttachArtwork() async {
        guard let url = primaryImageURL() else {
            LogTap.shared.note("[NowPlaying] artwork: no URL for item id=\(item.id) type=\(item.type)")
            return
        }
        LogTap.shared.note("[NowPlaying] artwork: GET \(url.absoluteString)")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            LogTap.shared.note("[NowPlaying] artwork: status=\(status) bytes=\(data.count)")
            guard let image = UIImage(data: data) else {
                LogTap.shared.note("[NowPlaying] artwork: UIImage decode failed")
                return
            }
            await applyArtwork(image: image)
        } catch {
            LogTap.shared.note("[NowPlaying] artwork: fetch failed: \(error.localizedDescription)")
        }
    }

    /// Build the `MPMediaItemArtwork` and stage it onto the info dict
    /// via a deferred main-queue write. Pre-extracts the `CGImage`
    /// outside the request handler so the closure never has to read
    /// the original `UIImage` from another thread; CGImage is immutable
    /// and free to retain across threads, UIImage in general is not.
    @MainActor
    private func applyArtwork(image: UIImage) {
        guard let cg = image.cgImage else {
            LogTap.shared.note("[NowPlaying] artwork: no CGImage on decoded UIImage")
            return
        }
        let size = image.size
        let scale = image.scale
        let artwork = MPMediaItemArtwork(boundsSize: size) { _ in
            UIImage(cgImage: cg, scale: scale, orientation: .up)
        }
        DispatchQueue.main.async {
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
}
