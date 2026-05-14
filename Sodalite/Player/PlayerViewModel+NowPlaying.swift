import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import AetherEngine

/// Apple TV system playback integration: the swipe-down info overlay
/// (`AVPlayerItem.externalMetadata`), the `MPNowPlayingInfoCenter`
/// dictionary that drives Control Center, and the
/// `MPRemoteCommandCenter` bindings that route hardware remote events
/// (play, pause, skip forward / back, scrub) back into the engine.
///
/// All three surfaces draw on the same `JellyfinItem` metadata; configure
/// once after `engine.load` returns, refresh on rate / time changes,
/// tear down on `stopPlayback`. Artwork fetch is async; the system shows
/// title + position immediately and the cover slots in when the bytes
/// land.
extension PlayerViewModel {

    // MARK: - Configure

    /// Called after `engine.load` returns. Builds the external-metadata
    /// items for the engine's `AVPlayerItem`, seeds `MPNowPlayingInfoCenter`,
    /// and wires `MPRemoteCommandCenter` handlers.
    func configureNowPlaying() {
        let baseURLString = playbackService.baseURL?.absoluteString
        let externalItems = buildExternalMetadataItems()
        player.setExternalMetadata(externalItems)

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = displayTitle
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        bindRemoteCommands()
        loadNowPlayingArtwork(baseURL: baseURLString)
    }

    /// Push the latest elapsed time + rate into `MPNowPlayingInfoCenter`.
    /// MediaPlayer extrapolates between updates from the last-reported
    /// elapsed + rate + timestamp, so calling this on every transport
    /// transition (play, pause, seek, episode change) is enough; per-tick
    /// updates would be wasted work.
    func refreshNowPlayingProgress() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        let duration = effectiveDuration
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Called from `stopPlayback`. Clears the now-playing dictionary and
    /// removes every remote-command target so a future PlayerView reload
    /// rebinds cleanly without stacking handlers.
    func teardownNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
    }

    // MARK: - Display strings

    private var displayTitle: String {
        if item.type == .episode, let name = item.name as String?, !name.isEmpty {
            return name
        }
        return item.name
    }

    /// Subtitle line ("Artist" slot in Control Center). For episodes the
    /// series name carries the most information; for movies the year is
    /// a useful disambiguator when several entries share a title.
    private var displaySubtitle: String? {
        if item.type == .episode, let series = item.seriesName, !series.isEmpty {
            return series
        }
        if let year = item.productionYear {
            return String(year)
        }
        return nil
    }

    /// "Album" slot. For episodes we surface "Season X • Episode Y" so
    /// the Control Center widget reads as "Show / Season 1 • Episode 3 /
    /// Title", matching what Jellyfin Web shows.
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

    // MARK: - External metadata for AVPlayerItem.externalMetadata

    /// Build metadata items the tvOS swipe-down overlay reads. Restricted
    /// to identifiers AVKit handles unambiguously across versions:
    ///   - title: any string
    ///   - description: any string
    ///   - artwork: image data, system probes JPEG / PNG / HEIF itself
    /// Rarer identifiers (creation-date, genre, content-rating, track
    /// subtitle) live in MPNowPlayingInfo / outside the overlay; they
    /// caused a swipe-down trap on tvOS 26 when value types didn't match
    /// the identifier's expected type (e.g. "2024" as String into a
    /// creation-date slot AVKit parsed as NSDate).
    private func buildExternalMetadataItems() -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        items.append(makeStringMetadataItem(identifier: .commonIdentifierTitle, value: displayTitle))
        // Episodes get a synthesized "Series • SxEy" line in the
        // description so the overlay surfaces the same context the
        // Control Center widget does, without needing a separate
        // subtitle identifier the overlay may parse strictly.
        let descriptionLines = [displayDescriptionPrefix, item.overview]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if !descriptionLines.isEmpty {
            items.append(makeStringMetadataItem(
                identifier: .commonIdentifierDescription,
                value: descriptionLines.joined(separator: "\n\n")
            ))
        }
        return items
    }

    /// One-line context prefix prepended to the description. For
    /// episodes: "Series Name • Season X • Episode Y". For movies with
    /// a year: "(2024)". Empty when neither applies.
    private var displayDescriptionPrefix: String? {
        if item.type == .episode {
            var parts: [String] = []
            if let series = item.seriesName, !series.isEmpty {
                parts.append(series)
            }
            if let season = item.parentIndexNumber {
                parts.append("Season \(season)")
            }
            if let ep = item.indexNumber {
                parts.append("Episode \(ep)")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " • ")
        }
        if let year = item.productionYear {
            return "(\(year))"
        }
        return nil
    }

    private func makeStringMetadataItem(identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    /// Artwork item with no explicit dataType so AVKit probes the bytes
    /// itself. Jellyfin returns JPEG by default; an explicit PNG type
    /// hint on JPEG bytes triggered the swipe-down crash on tvOS 26.
    private func makeArtworkMetadataItem(data: Data) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierArtwork
        item.value = data as NSData
        return item
    }

    // MARK: - Artwork

    /// Two-purpose fetch: feed the bytes into `MPMediaItemArtwork` so
    /// Control Center shows a cover, and re-publish the external-metadata
    /// list with an artwork item appended so the swipe-down info overlay
    /// shows the same image.
    private func loadNowPlayingArtwork(baseURL: String?) {
        guard let url = primaryImageURL(baseURL: baseURL) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else { return }
                await self.applyArtwork(image: image, data: data)
            } catch {
                // Silent; Control Center just shows the text fields without
                // a cover. Not worth surfacing to the user.
            }
        }
    }

    @MainActor
    private func applyArtwork(image: UIImage, data: Data) {
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        var ext = buildExternalMetadataItems()
        ext.append(makeArtworkMetadataItem(data: data))
        player.setExternalMetadata(ext)
    }

    /// Mirror of `episodeThumbnailURL` in `PlayerView` but biased toward
    /// a larger size: Control Center reads at 600pt on Apple TV's home
    /// strip, so a 800-wide source gives a sharp scale-down. Falls back
    /// the same way (item primary, item backdrop, series backdrop).
    private func primaryImageURL(baseURL: String?) -> URL? {
        guard let base = baseURL else { return nil }
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

    // MARK: - Remote command bindings

    private func bindRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if !self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.togglePlayPause() }
            return .success
        }

        let skip = Double(preferences.skipIntervalSeconds)
        center.skipForwardCommand.removeTarget(nil)
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skip)]
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            let amount = (event as? MPSkipIntervalCommandEvent)?.interval ?? skip
            Task { @MainActor in self.remoteSeek(by: amount) }
            return .success
        }

        center.skipBackwardCommand.removeTarget(nil)
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skip)]
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            let amount = (event as? MPSkipIntervalCommandEvent)?.interval ?? skip
            Task { @MainActor in self.remoteSeek(by: -amount) }
            return .success
        }

        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let evt = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let target = evt.positionTime
            Task { @MainActor in await self.player.seek(to: target) }
            return .success
        }
    }

    @MainActor
    private func remoteSeek(by seconds: Double) {
        let target = max(0, min(effectiveDuration, playbackTime + seconds))
        Task { await player.seek(to: target) }
    }
}
