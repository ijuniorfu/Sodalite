import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit
import AetherEngine

/// System Now Playing wiring.
///
/// Architecture combines three Apple-supported mechanisms:
///
/// 1. **AVPlayerViewController hosts the AVPlayer.** With
///    `showsPlaybackControls = false` AVKit's chrome and Siri Remote
///    gestures stay off, but AVKit still "owns" the AVPlayer for
///    audio routing — that's what unlocks tvOS 26's AirPods auto-
///    detection, Enhance Dialogue, Reduce Loud Sounds, synchronized
///    Atmos and the rest of the Apple-feature stack.
///
/// 2. **Explicit `MPNowPlayingSession` with auto-publish.** AVKit's
///    internal session is gated on `showsPlaybackControls = true` on
///    tvOS, so we drive the session ourselves against
///    `engine.currentAVPlayer`. Auto-publish handles rate, elapsed
///    time, duration, and the play / pause / scrubbing / seek remote
///    commands automatically off the AVPlayer.
///
/// 3. **`AVPlayerItem.externalMetadata` for title / description /
///    artwork.** The engine stages these via `setExternalMetadata`
///    before each load (engine applies to the AVPlayerItem before
///    AVPlayer.replaceCurrentItem so AVKit's first asset-metadata
///    read catches them). After load an async cover fetch re-stages
///    with the artwork attached; the engine writes directly to the
///    live AVPlayerItem.externalMetadata and the session re-publishes
///    automatically.
///
/// Zero direct writes to `MPNowPlayingInfoCenter.nowPlayingInfo` —
/// that path reproducibly trips `_dispatch_assert_queue_fail` inside
/// MediaPlayer's deferred dispatch chain on tvOS 26 in our setup,
/// independent of timing.
///
/// On audio-track switch the engine rebuilds NativeAVPlayerHost with
/// a fresh AVPlayer. `currentAVPlayer` publishes the swap and we
/// rebuild the session against the new instance. externalMetadata
/// is replayed by the engine onto the new AVPlayerItem so title /
/// cover stay across the switch.
extension PlayerViewModel {

    // MARK: - Pre-load externalMetadata stage

    /// Build static externalMetadata items (title, description) and
    /// stash them on the engine BEFORE `engine.load`. Engine applies
    /// them to the AVPlayerItem prior to replaceCurrentItem so the
    /// asset-metadata read window catches them on the first try.
    func stageInitialNowPlayingMetadata() {
        let items = buildExternalMetadataItems(artworkData: nil)
        player.setExternalMetadata(items)
    }

    // MARK: - Post-load artwork refresh

    /// Fetch the primary image asynchronously and re-stage
    /// externalMetadata with the artwork attached. Engine writes to
    /// the live AVPlayerItem; the session's auto-publish picks up the
    /// change. Failures leave the title-only metadata in place.
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
            guard let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.85) else {
                LogTap.shared.note("[NowPlaying] artwork: decode/re-encode failed")
                return
            }
            await MainActor.run {
                let items = self.buildExternalMetadataItems(artworkData: jpeg)
                self.player.setExternalMetadata(items)
            }
        } catch {
            LogTap.shared.note("[NowPlaying] artwork: fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - MPNowPlayingSession binding

    /// Subscribe to the engine's `$currentAVPlayer`. On each non-nil
    /// emission (initial load + every audio-track-switch rebuild) we
    /// recreate the session against the live AVPlayer so the system
    /// Now Playing card stays bound to the instance actually playing.
    /// externalMetadata stays on the AVPlayerItem across this swap
    /// (engine replays pendingExternalMetadata onto the new item).
    func startNowPlayingSessionBinding() {
        nowPlayingCancellable = player.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in
                guard let avPlayer else { return }
                self?.activateNowPlayingSession(for: avPlayer)
            }
    }

    private func activateNowPlayingSession(for avPlayer: AVPlayer) {
        let session = MPNowPlayingSession(players: [avPlayer])
        session.automaticallyPublishesNowPlayingInfo = true
        session.becomeActiveIfPossible { success in
            LogTap.shared.note("[NowPlaying] session active=\(success)")
        }
        nowPlayingSession = session
    }

    // MARK: - External metadata builder

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
