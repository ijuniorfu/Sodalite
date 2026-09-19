import Foundation
import AetherEngine

/// The one place that turns a resolved media source into the URL playback opens.
///
/// Lifted out of `PlayerViewModel.startPlayback` because a second caller appeared: warming a source
/// the app has not started yet (AetherEngine#551) only pays off if it warms the SAME URL the load
/// will later open, byte for byte. The engine adopts warmed bytes by exact URL, so two call sites
/// building that URL separately would work right up until one of them changed.
enum PlaybackStreamSelection {

    struct Resolved: Equatable, Sendable {
        let url: URL
        let method: PlayMethod

        /// Whether this URL may be warmed before anything asks to play it.
        ///
        /// Direct play and direct stream are a file the server hands over, and warming one costs it
        /// a range request. A transcode URL is neither: asking for it starts an ffmpeg session on
        /// the server for an item nobody is watching, and what comes back is an HLS playlist, which
        /// the engine plays through AVPlayer, where it issues no requests of its own and there is
        /// nothing for a later load to adopt. So the expensive one is also the useless one.
        var isWarmable: Bool { method != .transcode }
    }

    /// Mirrors the order `startPlayback` has always used: direct play, then direct stream, then the
    /// server's transcode path. nil means the source offers no route this app can open.
    static func resolve(itemID: String,
                        source: PlaybackMediaSource,
                        using service: JellyfinPlaybackServiceProtocol) -> Resolved? {
        if source.supportsDirectPlay == true || source.supportsDirectStream == true {
            let isDirectPlay = source.supportsDirectPlay == true
            guard let url = service.buildStreamURL(
                itemID: itemID,
                mediaSourceID: source.id,
                container: source.container,
                isStatic: isDirectPlay
            ) else { return nil }
            return Resolved(url: url, method: isDirectPlay ? .directPlay : .directStream)
        }
        if let transcodePath = source.transcodingUrl, !transcodePath.isEmpty,
           let url = service.buildTranscodeURL(relativePath: transcodePath) {
            return Resolved(url: url, method: .transcode)
        }
        return nil
    }

    /// The source the app would play out of a PlaybackInfo response, with no preference expressed.
    ///
    /// `startPlayback` prefers a named media source id (a version the user picked); an item nobody
    /// has opened yet has no such choice attached to it, so it takes the first, exactly as
    /// `startPlayback` does when its preference does not match.
    static func defaultSource(in response: PlaybackInfoResponse) -> PlaybackMediaSource? {
        response.mediaSources.first
    }

    /// Fetch the opening bytes of a source nobody has asked to play yet, so that pressing play does
    /// not pay for them (AetherEngine#551).
    ///
    /// Silent by design: a warm is an optimisation, and every reason it can decline (a metered
    /// origin, a transcode route, an origin that ignores ranges) is a reason to do nothing rather
    /// than to tell the user something. The engine logs what it did either way, so the diagnostic
    /// log carries it without this having to.
    static func warm(itemID: String,
                     source: PlaybackMediaSource,
                     using service: JellyfinPlaybackServiceProtocol) async {
        guard let resolved = resolve(itemID: itemID, source: source, using: service),
              resolved.isWarmable else { return }
        // Already warm: the engine would fetch the same bytes a second time and throw the first set
        // away, which is the one outcome worse than not warming at all.
        guard !AetherEngine.isPrewarmed(url: resolved.url) else { return }
        _ = await AetherEngine.prewarm(url: resolved.url)
    }
}
