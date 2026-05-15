import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import AetherEngine

/// System Now-Playing wiring for the AVPlayerViewController-hosted
/// native path. We don't write to `MPNowPlayingInfoCenter` at all,
/// and we don't bind remote commands ourselves. The host mounts an
/// `AVPlayerViewController` with `showsPlaybackControls = false` and
/// hands it `engine.currentAVPlayer`; AVKit's privileged code path
/// then drives the system Now Playing surface (title, artwork,
/// progress, rate, play/pause/skip remote commands) automatically by
/// reading off `AVPlayerItem.externalMetadata` and the AVPlayer's own
/// state.
///
/// Manual MPNowPlayingInfoCenter writes are the surface that
/// reproducibly tripped `_dispatch_assert_queue_fail` inside
/// MediaPlayer on tvOS 26 across 13+ iterations. The AVKit auto-
/// publish path doesn't go through the same deferred dispatch chain.
///
/// Flow:
///   1. `stageInitialNowPlayingMetadata` (BEFORE engine.load):
///      build title / description metadata items and hand them to
///      the engine via `setExternalMetadata`. The engine applies them
///      to the AVPlayerItem before AVPlayer.replaceCurrentItem so
///      AVKit's first asset-metadata read catches them.
///   2. `refreshExternalMetadataWithArtwork` (AFTER engine.load):
///      async-fetch the cover and re-call `setExternalMetadata` with
///      the artwork attached. Engine writes directly to the live
///      AVPlayerItem.externalMetadata, AVKit re-reads automatically.
///   3. No teardown logic. The host drops the AVPlayer reference
///      when the modal dismisses; AVKit clears its Now Playing
///      registration on its own.
extension PlayerViewModel {

    // MARK: - Stage initial metadata (pre-load)

    /// Build static externalMetadata items (title, description) and
    /// stash them on the engine BEFORE `engine.load`. The engine
    /// applies them to the AVPlayerItem prior to replaceCurrentItem
    /// so AVKit sees the metadata on its first asset-metadata read.
    func stageInitialNowPlayingMetadata() {
        let items = buildExternalMetadataItems(artworkData: nil)
        player.setExternalMetadata(items)
    }

    // MARK: - Refresh with artwork (post-load)

    /// Fetch primary artwork off-main, then re-stage externalMetadata
    /// with the cover attached. Called from `startPlayback` after
    /// `engine.load` returns. The engine writes the updated items to
    /// the live AVPlayerItem; AVKit picks up the change automatically.
    func refreshExternalMetadataWithArtwork() async {
        guard let url = primaryImageURL() else {
            LogTap.shared.note("[NowPlaying] artwork: no URL for item id=\(item.id)")
            return
        }
        LogTap.shared.note("[NowPlaying] artwork: GET \(url.absoluteString)")
        let request = URLRequest(url: url, timeoutInterval: 5.0)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            LogTap.shared.note("[NowPlaying] artwork: status=\(status) bytes=\(data.count)")
            // Re-encode to JPEG so the dataType hint is always
            // correct regardless of whether Jellyfin served JPEG /
            // PNG / HEIF. AVMetadataItem with a wrong dataType
            // sometimes silently fails the metadata pipeline.
            guard let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.85) else {
                LogTap.shared.note("[NowPlaying] artwork: decode/re-encode failed")
                return
            }
            await MainActor.run {
                let items = buildExternalMetadataItems(artworkData: jpeg)
                self.player.setExternalMetadata(items)
            }
        } catch {
            LogTap.shared.note("[NowPlaying] artwork: fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Metadata builder

    private func buildExternalMetadataItems(artworkData: Data?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        items.append(makeStringItem(.commonIdentifierTitle, item.name))
        if let descriptionLine = displayDescriptionLine {
            items.append(makeStringItem(.commonIdentifierDescription, descriptionLine))
        }
        if let data = artworkData {
            items.append(makeArtworkItem(data: data))
        }
        return items
    }

    /// One-line context shown alongside the title in the Now Playing
    /// card. For episodes: "SeriesName • Season 1 • Episode 3". For
    /// movies with a year: "(2024)". Empty when neither applies.
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

    private func makeArtworkItem(data: Data) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = .commonIdentifierArtwork
        m.value = data as NSData
        m.dataType = "public.jpeg"
        return m
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
