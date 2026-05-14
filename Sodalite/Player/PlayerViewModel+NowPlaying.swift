import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import AetherEngine

/// System Now-Playing integration. After verifying against:
///
/// - Apple's "Becoming a Now Playable App" sample (uses AVPlayer +
///   per-rate-change writes to MPNowPlayingInfoCenter)
/// - Jellyfin/Swiftfin's NowPlayableObserver (uses AVPlayerViewController
///   on tvOS which auto-populates MPNowPlayingInfoCenter internally,
///   plus manual writes for static metadata)
/// - WWDC 2022 "Explore media metadata publishing"
/// - WWDC 2017 "Now Playing and Remote Commands on tvOS"
///
/// What we have that breaks the proven patterns: Sodalite renders via a
/// custom `AetherPlayerView` (UIView + AVPlayerLayer), not AVPlayerViewController,
/// and the AVPlayer is wrapped by AetherEngine's HLS-loopback path
/// (127.0.0.1 + fMP4 segments produced lazily by HLSSegmentProducer).
/// On tvOS 26, multiple writes to `MPNowPlayingInfoCenter.nowPlayingInfo`
/// while this AVPlayer is in its initial seek / buffer churn
/// reproducibly trip `_dispatch_assert_queue_fail` inside MediaPlayer's
/// deferred barrier_async chain — a class of crash neither Apple's sample
/// (plain AVPlayer with file URLs) nor Swiftfin (AVPlayerViewController)
/// hits.
///
/// The hybrid path that combines the verified-stable pieces:
///
/// - `MPNowPlayingSession(players: [avPlayer])` with
///   `automaticallyPublishesNowPlayingInfo = true`. The session reads
///   runtime state (elapsed time, playback rate, play / pause) directly
///   off the AVPlayer and publishes to the system Now Playing surface.
///   Verified working: progress and pause state surface live in the
///   iPhone Control Center widget without any per-tick writes from us.
///
/// - One write to `MPNowPlayingInfoCenter.default().nowPlayingInfo` per
///   session, **after** a 2-second settle delay so AVPlayer is out of
///   its initial track-load / segment-fetch phase before the write
///   lands. Carries title / artist / album / artwork. The single-write
///   discipline is the one invariant that's held across every iteration
///   without crashing.
///
/// - The static-write is read-modify-write so it doesn't clobber the
///   dynamic keys (elapsed / rate / duration) that the session's
///   auto-publish populates.
extension PlayerViewModel {

    func configureNowPlaying() {
        guard let avPlayer = player.currentAVPlayer else { return }

        // Re-activate the audio session at the start of each playback
        // session. Apple's NowPlayable sample does this in
        // `handleNowPlayableSessionStart`; MediaPlayer uses the
        // activation event to identify the active Now Playing source.
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
        // publishStaticOnceAfterSettle() removed: even with a 2 s
        // settle delay the single MPNowPlayingInfoCenter write trips
        // the tvOS 26 libdispatch assert in MediaPlayer when paired
        // with our HLS-loopback AVPlayer. The session's auto-publish
        // alone gives us progress / pause state; static title +
        // artwork require either AVPlayerViewController migration or
        // accepting the gap.
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

        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    // MARK: - Single-write static metadata

    /// Wait 2 s for AVPlayer's initial setup churn to settle, then
    /// fetch artwork (5 s budget) and write the static fields exactly
    /// once. Single write per session is the one shape we've measured
    /// holding without crashes on tvOS 26.
    private func publishStaticOnceAfterSettle() async {
        try? await Task.sleep(for: .seconds(2))

        let title = item.name
        let subtitle = displaySubtitle
        let album = displayAlbum
        let artwork = await fetchArtwork()

        DispatchQueue.main.async {
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyTitle] = title
            if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
            if let album { info[MPMediaItemPropertyAlbumTitle] = album }
            if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
            info[MPNowPlayingInfoPropertyIsLiveStream] = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    // MARK: - Display strings

    private var displaySubtitle: String? {
        if item.type == .episode, let series = item.seriesName, !series.isEmpty {
            return series
        }
        if let year = item.productionYear {
            return String(year)
        }
        return nil
    }

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

    private func fetchArtwork() async -> MPMediaItemArtwork? {
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
            guard let image = UIImage(data: data) else {
                LogTap.shared.note("[NowPlaying] artwork: UIImage decode failed")
                return nil
            }
            guard let cg = image.cgImage else {
                LogTap.shared.note("[NowPlaying] artwork: no CGImage on decoded UIImage")
                return nil
            }
            let size = image.size
            let scale = image.scale
            return MPMediaItemArtwork(boundsSize: size) { _ in
                UIImage(cgImage: cg, scale: scale, orientation: .up)
            }
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
