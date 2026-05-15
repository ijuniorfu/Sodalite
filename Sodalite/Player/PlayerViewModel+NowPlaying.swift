import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit
import AetherEngine

/// System Now Playing wiring.
///
/// Architecture: one manual `MPNowPlayingInfoCenter.nowPlayingInfo`
/// write happens BEFORE `engine.load`. At that point no AVPlayer
/// exists yet, so the libdispatch race that crashed every prior
/// "write during AVPlayer reading from HLS-loopback" attempt cannot
/// fire. Title / description / artwork all ship in this single write.
///
/// After `engine.load`, an `MPNowPlayingSession` with
/// `automaticallyPublishesNowPlayingInfo = true` takes over the rest:
/// rate, elapsed time, duration, and the play / pause / scrubbing
/// remote commands are all auto-handled directly off the AVPlayer
/// (verified working without crashes across 731697f / 5c54524).
///
/// On audio-track switch the engine builds a fresh
/// `NativeAVPlayerHost` with a new AVPlayer; `currentAVPlayer`
/// publishes that swap and we rebuild the session against the new
/// instance. Title / description / artwork stay in the
/// MPNowPlayingInfoCenter dict across session changeover.
///
/// On dismiss a single `nowPlayingInfo = nil` write clears the card.
/// Nil-replace is the only full assignment that MediaPlayer accepts
/// without tripping the assertion (per memory).
extension PlayerViewModel {

    // MARK: - Post-load session (state / progress / remote commands)

    /// Subscribe to the engine's `$currentAVPlayer`. On each non-nil
    /// emission (initial load + every audio-track-switch rebuild) we
    /// recreate the session against the live AVPlayer so the system
    /// Now Playing card stays bound to the instance actually playing.
    /// Title / description / artwork live in the MPNowPlayingInfoCenter
    /// dict, independent of session lifetime, so session changeover
    /// doesn't blank the card.
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
        // becomeActiveIfPossible's completion fires once the system
        // has accepted us as the active Now Playing source; the
        // boolean is not actionable for us (Apple offers no remedy
        // for a denied activation), but logging the outcome helps
        // diagnose CC blanks if they happen again.
        session.becomeActiveIfPossible { success in
            LogTap.shared.note("[NowPlaying] session active=\(success)")
        }
        nowPlayingSession = session
    }

    // MARK: - Artwork pre-fetch

    /// Fetch the primary image as JPEG bytes with a hard timeout.
    /// Called from `startPlayback` in parallel with the playback-info
    /// request so the cover lands in time for the single pre-load
    /// MPNowPlayingInfoCenter write without adding latency. Returns
    /// nil if the request times out or fails; title-only Now Playing
    /// is an acceptable degradation.
    func prefetchArtworkData(timeoutSeconds: Double = 1.5) async -> Data? {
        guard let url = primaryImageURL() else { return nil }
        let request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            LogTap.shared.note("[NowPlaying] artwork prefetch status=\(status) bytes=\(data.count)")
            // Re-encode to JPEG so the data shape matches what
            // MPMediaItemArtwork expects regardless of whether
            // Jellyfin served PNG / HEIF.
            guard let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.85) else {
                LogTap.shared.note("[NowPlaying] artwork prefetch: decode/re-encode failed")
                return nil
            }
            return jpeg
        } catch {
            LogTap.shared.note("[NowPlaying] artwork prefetch failed: \(error.localizedDescription)")
            return nil
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
