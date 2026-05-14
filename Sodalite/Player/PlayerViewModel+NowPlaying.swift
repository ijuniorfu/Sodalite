import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import AetherEngine

/// System Now-Playing integration. With Phase 1 of the AVKit migration
/// in place, `AVPlayerViewController` owns the system Now Playing
/// surface end-to-end: progress / rate / state are tracked off the
/// AVPlayer automatically, and **static metadata flows from
/// `AVPlayerItem.externalMetadata` into the iPhone Lock Screen /
/// Control Center widget**.
///
/// This file's job is small:
///   1. Stage initial externalMetadata (title + subtitle) on the engine
///      BEFORE `engine.load`. The engine applies it to the
///      `AVPlayerItem` before `AVPlayer.replaceCurrentItem`, so AVKit
///      sees the values on the first asset-metadata read.
///   2. After the artwork fetch resolves, re-stage externalMetadata
///      with the cover added. The engine writes to the live
///      AVPlayerItem; AVKit picks up the update automatically.
///
/// No MPNowPlayingInfoCenter writes anywhere in this file (that path
/// is what crashed across the previous six iterations). No
/// MPRemoteCommandCenter bindings (AVKit registers the system
/// commands itself). No MPNowPlayingSession (redundant with AVKit's
/// internal integration).
extension PlayerViewModel {

    /// Build and stage the initial externalMetadata before `engine.load`.
    /// Called from `startPlayback` so the items are present on the
    /// AVPlayerItem when AVKit reads asset metadata.
    func stageInitialNowPlayingMetadata() {
        let items = buildExternalMetadataItems(image: nil)
        player.setExternalMetadata(items)
    }

    /// Called from PlayerHostController after the AVPlayer is handed to
    /// AVKit. Fetches artwork off-main, then re-stages externalMetadata
    /// with the cover so the system widget gets the image.
    func configureNowPlaying() {
        Task { [weak self] in await self?.refreshExternalMetadataWithArtwork() }
    }

    /// No-op retained so existing callers don't break.
    func refreshNowPlayingProgress() {
        // AVKit handles dynamic state.
    }

    func teardownNowPlaying() {
        player.setExternalMetadata([])
    }

    // MARK: - External metadata build

    private func buildExternalMetadataItems(image: UIImage?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        items.append(makeStringItem(.commonIdentifierTitle, item.name))
        if let subtitleLine = displayDescriptionLine {
            items.append(makeStringItem(.commonIdentifierDescription, subtitleLine))
        }
        if let image, let data = image.jpegData(compressionQuality: 0.85) {
            items.append(makeArtworkItem(data: data))
        }
        return items
    }

    /// One-line context shown alongside the title. For episodes:
    /// "SeriesName • Season 1 • Episode 3". For movies: year.
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
    /// (via `UIImage.jpegData`) so the dataType hint matches the data
    /// regardless of what Jellyfin originally served. A mismatched
    /// hint (PNG type on JPEG bytes) was the original swipe-down
    /// crash trigger; now that AVKit owns the in-player chrome the
    /// risk is lower but the correct hint is still the safer call.
    private func makeArtworkItem(data: Data) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = .commonIdentifierArtwork
        m.value = data as NSData
        m.dataType = kCMMetadataBaseDataType_JPEG as String
        m.extendedLanguageTag = "und"
        return m
    }

    // MARK: - Artwork fetch

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
}
