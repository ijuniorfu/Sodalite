import Foundation
import MediaPlayer
import UIKit

/// System Now-Playing integration: populates the dictionary
/// `MPNowPlayingInfoCenter.default()` surfaces to Apple's external
/// audio/video clients (Apple TV's Control Center widget, nearby iPhone
/// Remote / Lock-Screen "Now Playing" tile, HomePod display, Siri
/// "Pause" voice control), and routes the corresponding
/// `MPRemoteCommandCenter` actions back into the engine.
///
/// Does NOT touch `AVPlayerItem.externalMetadata`; that surface drives
/// the in-player swipe-down info overlay, which Sodalite intentionally
/// leaves bare (the detail sheet shows the same context the user would
/// scroll back through during playback).
///
/// Threading note: every `MPNowPlayingInfoCenter.default().nowPlayingInfo =`
/// write goes through `DispatchQueue.main.async`. The setter dispatches
/// internal work via `dispatch_barrier_async` to its own serial queue
/// and the follow-up work re-enters via `dispatch_after` /
/// `dispatch_barrier_async`. Calling the setter directly from a Combine
/// sink that just ran on main triggered a `_dispatch_assert_queue_fail`
/// 10-15 s into playback on tvOS 26 (Thread 17 EXC_BREAKPOINT). Deferring
/// every write to the next main-runloop tick breaks the reentrancy
/// path. Same reasoning for the remote-command callbacks: hop via
/// `DispatchQueue.main.async` instead of `Task { @MainActor in }` so we
/// don't intermix dispatch queues with actor hops on the same callback.
extension PlayerViewModel {

    // MARK: - Configure

    /// Call once after `engine.load` returns and the session is live.
    /// Binds remote commands first (so the system sees a Now-Playing-
    /// eligible app before any info-dict write lands), then publishes
    /// the initial dictionary, then kicks off an async artwork fetch.
    func configureNowPlaying() {
        bindRemoteCommands()
        publishStaticNowPlayingFields()
        refreshNowPlayingProgress()
        Task { [weak self] in await self?.loadAndAttachArtwork() }
    }

    /// Push the latest elapsed time + rate. MediaPlayer extrapolates
    /// between updates from the last-reported elapsed + rate + timestamp,
    /// so calling this on every transport transition (play, pause, seek,
    /// episode change) is sufficient; per-tick updates would just churn
    /// the dictionary.
    func refreshNowPlayingProgress() {
        let elapsed = playbackTime
        let rate = isPlaying ? 1.0 : 0.0
        let duration = effectiveDuration
        mutateNowPlayingInfo { info in
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
            info[MPNowPlayingInfoPropertyPlaybackRate] = rate
            if duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
        }
    }

    /// Pair to `configureNowPlaying`. Clears the dictionary so the
    /// system surfaces drop the entry, and removes our remote-command
    /// handlers so a future PlayerView reload binds cleanly.
    func teardownNowPlaying() {
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
    }

    // MARK: - Dictionary helpers

    /// Deferred read-modify-write of the now-playing dictionary. Always
    /// runs on main, always deferred via `async` so we can't be inside
    /// `MPNowPlayingInfoCenter`'s internal serial queue while issuing
    /// another write.
    private func mutateNowPlayingInfo(_ mutate: @escaping (inout [String: Any]) -> Void) {
        DispatchQueue.main.async {
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            mutate(&info)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private func publishStaticNowPlayingFields() {
        let title = displayTitle
        let subtitle = displaySubtitle
        let album = displayAlbum
        mutateNowPlayingInfo { info in
            info[MPMediaItemPropertyTitle] = title
            if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
            if let album { info[MPMediaItemPropertyAlbumTitle] = album }
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        }
    }

    // MARK: - Display strings

    private var displayTitle: String { item.name }

    /// "Artist" slot. Series name for episodes, year for movies, nil
    /// for the rest. Series gets priority over year because that's the
    /// disambiguator most users actually read.
    private var displaySubtitle: String? {
        if item.type == .episode, let series = item.seriesName, !series.isEmpty {
            return series
        }
        if let year = item.productionYear {
            return String(year)
        }
        return nil
    }

    /// "Album" slot. Only meaningful for episodes ("Season X • Episode Y").
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
    /// `MPMediaItemArtwork`. Off-main fetch, deferred mutate of the
    /// dictionary. Silent on failure; LogTap notes record outcomes so
    /// missing covers can be debugged from the in-app log buffer.
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

    @MainActor
    private func applyArtwork(image: UIImage) {
        let size = image.size
        let artwork = MPMediaItemArtwork(boundsSize: size) { _ in image }
        mutateNowPlayingInfo { info in
            info[MPMediaItemPropertyArtwork] = artwork
        }
    }

    /// Build the primary-image URL directly off `playbackService.baseURL`
    /// + the item's image tags, mirroring the pattern PlayerView already
    /// uses for episode-thumbnail URLs. 800-wide source is sharp enough
    /// for the ~600pt slot the system widget renders into.
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

    /// Bind play / pause / toggle to engine transport. Handlers defer
    /// the engine call via `DispatchQueue.main.async` (not `Task @MainActor`)
    /// so we don't intermix dispatch hops and actor hops inside the
    /// MediaPlayer XPC reply chain. Scrubber and skip commands stay off
    /// for now; bring them in once these three are confirmed stable on
    /// tvOS 26.
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
