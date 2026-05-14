import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import AetherEngine

/// System Now-Playing integration via `MPNowPlayingSession`'s
/// automatic-publishing path, the documented tvOS 14+ flow for non-AVKit
/// custom players. The session reads metadata directly off the
/// `AVPlayerItem.externalMetadata` and reads runtime state off the
/// `AVPlayer` it was constructed with; the host never touches
/// `MPNowPlayingInfoCenter.nowPlayingInfo`. That direct path was the
/// crash surface in the earlier iterations — every manual write into
/// `nowPlayingInfo` while AVPlayer was in its initial seek / buffer
/// churn tripped `_dispatch_assert_queue_fail` somewhere inside
/// MediaPlayer's deferred dispatch chain, regardless of whether the
/// call went through `MainActor.run` or `DispatchQueue.main.async`.
///
/// Critical timing: `externalMetadata` is staged into the engine
/// BEFORE `engine.load`, from `stageInitialNowPlayingMetadata`. The
/// engine applies it to the AVPlayerItem before AVPlayer.replaceCurrentItem,
/// so the asset-metadata-read window catches it on the first try.
/// Setting `externalMetadata` after the asset is already loaded races
/// AVPlayer's track-load and the system caches empty metadata.
extension PlayerViewModel {

    // MARK: - Stage / configure / teardown

    /// Build static externalMetadata items (title, description) and
    /// hand them to the engine BEFORE `engine.load`. Called from
    /// `startPlayback` so the engine's load() can apply them to the
    /// AVPlayerItem prior to `replaceCurrentItem`.
    func stageInitialNowPlayingMetadata() {
        let items = buildExternalMetadataItems(image: nil)
        player.setExternalMetadata(items)
    }

    func configureNowPlaying() {
        guard let avPlayer = player.currentAVPlayer else { return }

        // Re-activate the audio session so MediaPlayer's now-playing
        // state machine treats this as a fresh playback session,
        // matching Apple's "Becoming a Now Playable App" sample.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            LogTap.shared.note("[NowPlaying] AVAudioSession.setActive failed: \(error.localizedDescription)")
        }

        let session = MPNowPlayingSession(players: [avPlayer])
        session.automaticallyPublishesNowPlayingInfo = true
        nowPlayingSession = session
        session.becomeActiveIfPossible { _ in /* result not actionable */ }

        bindRemoteCommands(session: session)

        // Fetch artwork off-main, then re-stage externalMetadata with
        // the cover added. The engine writes to the live AVPlayerItem;
        // MPNowPlayingSession reads the updated externalMetadata
        // automatically.
        Task { [weak self] in await self?.refreshExternalMetadataWithArtwork() }
    }

    func refreshNowPlayingProgress() {
        // No-op. Auto-publish handles state tracking.
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

        // Clear externalMetadata on the engine so a future session
        // doesn't replay stale items.
        player.setExternalMetadata([])
    }

    // MARK: - External metadata build

    private func buildExternalMetadataItems(image: UIImage?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        items.append(makeStringItem(.commonIdentifierTitle, item.name))
        if let descriptionLine = displayDescriptionLine {
            items.append(makeStringItem(.commonIdentifierDescription, descriptionLine))
        }
        if let image, let data = image.jpegData(compressionQuality: 0.85) {
            items.append(makeArtworkItem(data: data))
        }
        return items
    }

    /// One-line context shown alongside the title. For episodes:
    /// "SeriesName • Season 1 • Episode 3". For movies with a year:
    /// "(2024)". Empty when neither applies.
    private var displayDescriptionLine: String? {
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

    private func makeStringItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = identifier
        m.value = value as NSString
        m.extendedLanguageTag = "und"
        return m
    }

    /// Artwork as JPEG bytes. We re-encode to JPEG ourselves
    /// (via `UIImage.jpegData`) so the dataType hint is always
    /// correct regardless of what Jellyfin originally served.
    /// Feeding AVKit a wrong dataType (PNG hint on JPEG bytes)
    /// was the original swipe-down crash trigger.
    private func makeArtworkItem(data: Data) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = .commonIdentifierArtwork
        m.value = data as NSData
        m.dataType = kCMMetadataBaseDataType_JPEG as String
        m.extendedLanguageTag = "und"
        return m
    }

    // MARK: - Artwork fetch

    /// Off-main fetch, then re-stage externalMetadata with the image.
    /// Falls through silently on failure; the card stays text-only.
    private func refreshExternalMetadataWithArtwork() async {
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
            await MainActor.run {
                let items = self.buildExternalMetadataItems(image: image)
                self.player.setExternalMetadata(items)
            }
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
