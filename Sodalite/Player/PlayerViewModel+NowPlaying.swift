import Foundation
import AVFoundation
import MediaPlayer
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
        player.setExternalMetadata(items)
    }

    // MARK: - Remote commands (empty-session side-channel)

    /// Experimental: create an `MPNowPlayingSession` with NO players
    /// (`players: []`) and bind skip-forward / skip-backward targets
    /// on its own `remoteCommandCenter`. AVKit's internal session
    /// still owns the AVPlayer for play / pause / scrub on iPhone CC;
    /// our empty session sits alongside for the commands AVKit
    /// doesn't expose to user code.
    ///
    /// Why this might work: prior attempts at an explicit
    /// `MPNowPlayingSession(players: [avPlayer])` (d30bace) crashed
    /// with CoreMediaErrorDomain -16046 because two sessions tried to
    /// claim the same AVPlayer. The empty-player variant has no
    /// AVPlayer ownership to conflict over. If the system routes CC
    /// skip presses to ANY active session's command center, ours
    /// could catch them while AVKit handles the rest.
    ///
    /// Why this might not work: per Apple docs "only one
    /// MPNowPlayingSession is active at a time". Calling
    /// `becomeActiveIfPossible` could deactivate AVKit's session,
    /// breaking the title / cover / scrub display in CC. We log the
    /// activation outcome to find out.
    func bindRemoteSkipCommands() {
        let session = MPNowPlayingSession(players: [])
        // Don't auto-publish — that would race manual nowPlayingInfo
        // mutations against AVKit's internal session and bring back
        // the libdispatch assert that brought down every prior
        // manual-write iteration.
        session.automaticallyPublishesNowPlayingInfo = false
        nowPlayingSession = session

        let center = session.remoteCommandCenter

        center.skipForwardCommand.removeTarget(nil)
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval: Double
            if let skipEvent = event as? MPSkipIntervalCommandEvent {
                interval = skipEvent.interval > 0 ? skipEvent.interval : 10
            } else {
                interval = 10
            }
            print("[NowPlaying] empty-session skipForward fired interval=\(interval)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.player.seek(to: self.player.currentTime + interval)
            }
            return .success
        }

        center.skipBackwardCommand.removeTarget(nil)
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval: Double
            if let skipEvent = event as? MPSkipIntervalCommandEvent {
                interval = skipEvent.interval > 0 ? skipEvent.interval : 10
            } else {
                interval = 10
            }
            print("[NowPlaying] empty-session skipBackward fired interval=\(interval)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.player.seek(to: max(0, self.player.currentTime - interval))
            }
            return .success
        }

        session.becomeActiveIfPossible { success in
            print("[NowPlaying] empty-session becomeActive=\(success)")
        }
    }

    /// Tear down the empty session. Called from stopPlayback.
    func unbindRemoteSkipCommands() {
        if let session = nowPlayingSession {
            session.remoteCommandCenter.skipForwardCommand.removeTarget(nil)
            session.remoteCommandCenter.skipBackwardCommand.removeTarget(nil)
        }
        nowPlayingSession = nil
    }

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
