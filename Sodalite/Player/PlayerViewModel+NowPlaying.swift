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
extension PlayerViewModel {

    // MARK: - Configure

    /// Call once after `engine.load` returns and the session is live.
    /// Builds the initial Now-Playing dictionary, binds the three
    /// transport-control remote commands, and kicks off an async
    /// artwork fetch that fills in the cover when the image bytes land.
    func configureNowPlaying() {
        publishStaticNowPlayingFields()
        refreshNowPlayingProgress()
        bindRemoteCommands()
        Task { [weak self] in await self?.loadAndAttachArtwork() }
    }

    /// Push the latest elapsed time + rate. MediaPlayer extrapolates
    /// between updates from the last-reported elapsed + rate + timestamp,
    /// so calling this on every transport transition (play, pause, seek,
    /// episode change) is sufficient; per-tick updates would just churn
    /// the dictionary.
    func refreshNowPlayingProgress() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        let dur = effectiveDuration
        if dur > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = dur
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Pair to `configureNowPlaying`. Clears the dictionary so the
    /// system surfaces drop the entry, and removes our remote-command
    /// handlers so a future PlayerView reload binds cleanly.
    func teardownNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
    }

    // MARK: - Dictionary build

    private func publishStaticNowPlayingFields() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = displayTitle
        if let subtitle = displaySubtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if let album = displayAlbum {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
    /// `MPMediaItemArtwork`. Off-main fetch, main-actor hop to mutate
    /// the dictionary. Silent on failure; the Now Playing card just
    /// shows text-only.
    private func loadAndAttachArtwork() async {
        guard let url = primaryImageURL() else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return }
            await applyArtwork(image: image)
        } catch {
            // Network failure / image decode failure: no card cover.
            // Not worth surfacing to the user.
        }
    }

    @MainActor
    private func applyArtwork(image: UIImage) {
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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

    /// Bind play / pause / toggle to engine transport. Deliberately
    /// limited to these three: skip-forward / skip-backward / position
    /// scrubber commands are valuable but add surface; bring them in
    /// once the basic three are confirmed stable on tvOS 26.
    private func bindRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
    }
}
