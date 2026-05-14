import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import AetherEngine

/// System Now-Playing integration following Apple's WWDC22 guidance
/// ("Explore media metadata publishing and playback interactions"):
///
/// 1. Hand the engine's `AVPlayer` instance to `MPNowPlayingSession`.
/// 2. Enable `automaticallyPublishesNowPlayingInfo`. The session then
///    tracks elapsed time, rate, and play / pause state directly off
///    the AVPlayer and publishes them into the system Now Playing
///    surface (Apple TV Control Center, nearby iPhone Lock-Screen
///    widget, HomePod display, Siri voice control).
/// 3. Publish *static* metadata (title, artwork) through
///    `AVPlayerItem.externalMetadata` — NOT through
///    `MPNowPlayingInfoCenter.nowPlayingInfo`. Mixing those two paths
///    on tvOS 26 caused `_dispatch_assert_queue_fail` inside MediaPlayer
///    every time we tried a second write to nowPlayingInfo.
///
/// Static metadata is set exactly once per session, after the artwork
/// fetch returns (or fails). One single point where the AVPlayerItem
/// learns about title + cover.
extension PlayerViewModel {

    func configureNowPlaying() {
        guard let avPlayer = player.currentAVPlayer else { return }

        let session = MPNowPlayingSession(players: [avPlayer])
        session.automaticallyPublishesNowPlayingInfo = true
        nowPlayingSession = session
        session.becomeActiveIfPossible { _ in /* result not actionable */ }

        bindRemoteCommands(session: session)

        // Static metadata: fetch artwork in the background, then publish
        // a single externalMetadata array containing whatever we have.
        // No MPNowPlayingInfoCenter writes anywhere in this file.
        Task { [weak self] in await self?.publishExternalMetadata() }
    }

    func refreshNowPlayingProgress() {
        // Intentionally empty. Auto-publish handles elapsed / rate.
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

        player.setExternalMetadata([])
    }

    // MARK: - External metadata (single-write per session)

    private func publishExternalMetadata() async {
        let title = item.name
        let subtitleLine = displaySubtitleLine
        let artworkData = await fetchArtworkData()

        var items: [AVMetadataItem] = []
        items.append(makeStringItem(.commonIdentifierTitle, title))
        if let subtitle = subtitleLine {
            // Use commonIdentifierDescription for the contextual line
            // ("SeriesName • Season 1 • Episode 3" for episodes, year
            // alone for movies). It's the safest string slot to fill.
            items.append(makeStringItem(.commonIdentifierDescription, subtitle))
        }
        if let data = artworkData {
            items.append(makeArtworkItem(data: data))
        }

        await MainActor.run { player.setExternalMetadata(items) }
    }

    private func makeStringItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = identifier
        m.value = value as NSString
        m.extendedLanguageTag = "und"
        return m
    }

    /// Build the artwork metadata item. Detects JPEG vs PNG from the
    /// magic bytes so the correct `dataType` hint can be set; AVKit
    /// uses that hint to decode without sniffing the bytes itself,
    /// and feeding it the wrong hint (PNG type on JPEG bytes) was the
    /// crash trigger in the earlier in-player-overlay attempt.
    private func makeArtworkItem(data: Data) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = .commonIdentifierArtwork
        m.value = data as NSData
        m.extendedLanguageTag = "und"
        if data.count >= 4 {
            let header = data.prefix(4)
            if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                m.dataType = kCMMetadataBaseDataType_PNG as String
            } else if header.starts(with: [0xFF, 0xD8, 0xFF]) {
                m.dataType = kCMMetadataBaseDataType_JPEG as String
            }
            // Otherwise leave dataType unset so AVKit probes the bytes.
        }
        return m
    }

    /// One-line context shown below the title. Series + "Season X •
    /// Episode Y" for episodes, year for movies, nil for everything else.
    private var displaySubtitleLine: String? {
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

    // MARK: - Remote commands

    /// Auto-publish handles outbound state, but the inbound transport
    /// commands users issue via HomePod / Siri / iPhone Remote still
    /// need explicit handlers to route into the engine. Callbacks defer
    /// the engine call to main via DispatchQueue.main.async; mixing
    /// dispatch hops with actor hops inside MediaPlayer's XPC reply
    /// chain correlated with the earlier libdispatch assertion.
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

    // MARK: - Artwork fetch

    private func fetchArtworkData() async -> Data? {
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
            return data
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
}
