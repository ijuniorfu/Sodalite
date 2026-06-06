import Foundation
import AVFoundation
import UIKit
import AetherEngine

/// System Now Playing wiring via `AVPlayerItem.externalMetadata`.
///
/// AVKit's internal Now Playing session (activated by
/// `AVPlayerViewController.showsPlaybackControls = true`) reads
/// title / description / artwork from `AVPlayerItem.externalMetadata`
/// and publishes them to MPNowPlayingInfoCenter, plus drives rate /
/// elapsed time / remote-command targets directly off the AVPlayer.
/// The host VC suppresses every visible AVKit chrome element via
/// `playbackControlsIncludeTransportBar = false` /
/// `playbackControlsIncludeInfoViews = false`, so the user only sees
/// our custom UI; AVKit's backend stays active for the privileged
/// features (AirPods auto-detection, Enhance Dialogue, Reduce Loud
/// Sounds, synchronized Atmos).
///
/// Flow:
///   1. `stageInitialNowPlayingMetadata` (BEFORE engine.load):
///      builds title + description as AVMetadataItems and hands them
///      to the engine via `setExternalMetadata`. Engine applies them
///      to the AVPlayerItem before AVPlayer.replaceCurrentItem so
///      AVKit's first asset-metadata read catches them.
///   2. `refreshExternalMetadataWithArtwork` (AFTER engine.load):
///      async-fetches the cover and re-stages externalMetadata with
///      artwork attached. Engine writes directly to the live
///      AVPlayerItem.externalMetadata; AVKit re-reads automatically.
///
/// Across audio-track-switch reloads the engine builds a fresh
/// NativeAVPlayerHost and replays pendingExternalMetadata onto the
/// new AVPlayerItem, so title/cover stay across the switch without
/// any extra host-side wiring.
extension PlayerViewModel {

    // MARK: - Pre-load externalMetadata stage

    /// Build static externalMetadata items (title, description) and
    /// stash them on the engine BEFORE `engine.load`. Engine applies
    /// them to the AVPlayerItem prior to replaceCurrentItem so the
    /// asset-metadata read window catches them on the first try.
    func stageInitialNowPlayingMetadata() {
        let items = buildExternalMetadataItems(artworkData: nil)
        LogTap.shared.note("[NowPlaying] stage id=\(item.id) items=\(items.count)")
        player.setExternalMetadata(items)
    }

    // MARK: - Remote commands (documented-API dead end)

    /// CC 10s skip-forward / skip-backward buttons are visible in the
    /// iPhone Control Center widget for our setup but pressing them
    /// dispatches nowhere we can hook from user code:
    ///   - `MPRemoteCommandCenter.shared().skipForwardCommand` targets
    ///     are dormant — CC routes to AVKit's per-session command
    ///     center, not shared (verified c54fcb7).
    ///   - `AVPlayerViewControllerDelegate.skipToNextItem` /
    ///     `skipToPreviousItem` with `skippingBehavior = .skipItem`
    ///     never fire from CC (verified 8d8e154).
    ///   - `AVPlayerViewControllerDelegate.timeToSeekAfterUserNavigatedFrom`
    ///     DOES fire for in-player and CC scrub events but NOT for
    ///     skip-by-interval button presses (verified 7ed793d / cd890d5).
    ///   - An explicit `MPNowPlayingSession(players: [dummyPlayer])`
    ///     activated successfully alongside AVKit's session (so the
    ///     two CAN coexist) — but the system still didn't route CC
    ///     skip presses to its `remoteCommandCenter` targets
    ///     (verified cd890d5).
    ///   - Manual `MPNowPlayingInfoCenter.nowPlayingInfo` writes
    ///     crash with `_dispatch_assert_queue_fail` regardless of
    ///     socket framework backing the HLS loopback (NWConnection
    ///     and BSD sockets both verified, the latter via engine
    ///     refactor 962292d).
    ///   - `AVAssetResourceLoaderDelegate` for HLS segments is
    ///     rejected by AVPlayer per Apple Forum 113063.
    ///
    /// Only remaining path: private API (KVC-reach
    /// `AVPlayerViewController._nowPlayingSession`). Not worth the
    /// App Store reject risk for a single decorative CC button.
    /// Everything else of the Apple feature stack — title / cover /
    /// scrubbing / play/pause / AirPods auto-detection / Enhance
    /// Dialogue / Reduce Loud Sounds / synchronized Atmos — works.
    func bindRemoteSkipCommands() {}
    func unbindRemoteSkipCommands() {}

    // MARK: - Post-load artwork refresh

    /// Fetch the primary image asynchronously and re-stage
    /// externalMetadata with the artwork attached. Engine writes to
    /// the live AVPlayerItem; AVKit's internal Now Playing session
    /// re-reads on the next publish tick. Failures leave the
    /// title-only metadata in place.
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

    // MARK: - External metadata builder

    private func buildExternalMetadataItems(artworkData: Data?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        items.append(makeStringItem(.commonIdentifierTitle, nowPlayingTitle))
        if let descriptionLine = displayDescriptionLine {
            items.append(makeStringItem(.commonIdentifierDescription, descriptionLine))
        }
        if let data = artworkData {
            items.append(makeArtworkItem(data: data))
        }
        return items
    }

    /// System Now-Playing title. The iPhone Control Center remote widget
    /// only surfaces this one content line (the gray line above it is the
    /// Apple TV's route name, owned by the system, not our description),
    /// so for episodes we fold the series and SxxExx into the title:
    /// "Bluey · S2E5 · Schnuffis guter Riecher". Without this the widget
    /// showed only the episode name, with no show or episode number
    /// (issue #15). Movies keep their plain title.
    private var nowPlayingTitle: String {
        guard item.type == .episode else { return item.name }
        var parts: [String] = []
        if let series = item.seriesName, !series.isEmpty {
            parts.append(series)
        }
        var seasonEpisode = ""
        if let season = item.parentIndexNumber {
            seasonEpisode += "S\(season)"
        }
        if let ep = item.indexNumber {
            seasonEpisode += "E\(ep)"
        }
        if !seasonEpisode.isEmpty {
            parts.append(seasonEpisode)
        }
        if !item.name.isEmpty {
            parts.append(item.name)
        }
        return parts.isEmpty ? item.name : parts.joined(separator: " · ")
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
