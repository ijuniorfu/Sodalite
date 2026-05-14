import Foundation
import MediaPlayer
import UIKit

/// System Now-Playing integration. Phase 1 here is intentionally minimal
/// while we narrow down a tvOS 26 _dispatch_assert_queue_fail that
/// surfaces 10-15 s into playback whenever the previous, fuller wiring
/// (refresh-on-state-transition, async artwork attach, remote-command
/// callbacks) ran.
///
/// What's wired right now:
///   - `MPNowPlayingInfoCenter.nowPlayingInfo` gets a single write after
///     load, carrying title / artist / album / duration / initial
///     elapsed + rate.
///   - That's it. No mid-session updates, no artwork, no remote-command
///     handlers.
///
/// Once this version is confirmed stable, layer back in (one PR each):
///   - Remote-command handlers (play, pause, toggle).
///   - Periodic elapsed-time refresh (probably timer-driven, not
///     Combine-state driven).
///   - Artwork via MPMediaItemArtwork.
extension PlayerViewModel {

    func configureNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = item.name
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

        // Single deferred write, no follow-ups. If MediaPlayer's internal
        // serial queue still trips its assertion from THIS alone, the
        // problem is MPNowPlayingInfoCenter itself on tvOS 26 and we
        // should drop the whole feature.
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// No-op for now. Kept as the entry point the state observer calls
    /// so a later commit can wire periodic / event-driven refresh back
    /// in without touching PlayerViewModel.swift again.
    func refreshNowPlayingProgress() {
        // Intentionally empty during the tvOS 26 crash bisect.
    }

    func teardownNowPlaying() {
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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
}
