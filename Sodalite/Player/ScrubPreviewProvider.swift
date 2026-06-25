import Foundation
import CoreGraphics
import AetherEngine

/// Session-scoped scrub-preview source. Configured per session with the
/// session's `FrameExtractor`, driven by `update(fraction:durationSeconds:)`,
/// publishes a ready-to-draw `CGImage`. Extractor (owned by PlayerViewModel)
/// does decode/caching/cancel-on-supersede; nil image -> show time only.
@Observable
@MainActor
final class ScrubPreviewProvider {

    /// Frame to draw above the playhead; nil = show time only.
    private(set) var previewImage: CGImage?

    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var extractor: FrameExtractor?
    /// Live mode: thumbnails from the engine's DVR segment cache (seconds,
    /// maxWidth) instead of a session FrameExtractor.
    @ObservationIgnored private var liveThumbnail: ((Double, Int) async -> CGImage?)?
    /// VOD server-trickplay source: seconds -> cropped tile image. Mutually exclusive
    /// with the FrameExtractor source; reset() clears it. Mirrors `liveThumbnail`: a
    /// MainActor closure that does its placement/URL work, then hops off-actor to fetch.
    @ObservationIgnored private var serverThumbnail: ((Double) async -> CGImage?)?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    // Last warmed source seconds, throttles re-extraction to ~keyframe spacing.
    @ObservationIgnored private var lastWarmedSeconds = -Double.infinity
    @ObservationIgnored private let warmThresholdSeconds: Double = 2

    init() {}

    /// Set up for a new session. `enabled` = Settings toggle (false = no-op);
    /// `extractor` nil if the source URL couldn't be built.
    func configure(extractor: FrameExtractor?, enabled: Bool) {
        reset()
        self.extractor = extractor
        self.enabled = enabled
    }

    /// Use a Jellyfin server-trickplay closure as the VOD scrub source instead of the
    /// FrameExtractor. Mutually exclusive with configure(extractor:); reset() clears both.
    func configure(serverThumbnail: @escaping (Double) async -> CGImage?, enabled: Bool) {
        reset()
        self.serverThumbnail = serverThumbnail
        self.enabled = enabled
    }

    /// Set up for a live session, mutually exclusive with
    /// `configure(extractor:enabled:)` (reset() clears both). Closure retained
    /// until next reset(); capture the engine weakly (process-wide singleton).
    func configureLive(enabled: Bool, thumbnail: @escaping (Double, Int) async -> CGImage?) {
        reset()
        self.liveThumbnail = thumbnail
        self.enabled = enabled
    }

    /// Live drive: absolute session-timeline seconds (`liveSeekableRange`
    /// domain). The fraction-based `update` is VOD-only (live duration is 0).
    /// Shares the debounce + generation guard.
    func update(targetSeconds: Double) {
        guard enabled, let liveThumbnail else { return }
        generation += 1
        let gen = generation
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            if Task.isCancelled { return }
            let image = await liveThumbnail(targetSeconds, 320)
            guard let self else { return }
            if gen == self.generation { self.previewImage = image }
        }
    }

    /// Open the decode context ahead of the first scrub frame to hide
    /// cold-start latency. Idempotent.
    func prewarm() {
        guard enabled, let extractor else { return }
        Task { await extractor.prewarm() }
    }

    /// Drive the preview to a scrub position (`fraction` 0...1). Debounced so a
    /// fast swipe doesn't decode per frame; `generation` guard drops stale results.
    func update(fraction: Float, durationSeconds: Double) {
        guard enabled, durationSeconds > 0 else { return }
        let seconds = Double(max(0, min(1, fraction))) * durationSeconds
        let server = serverThumbnail
        let ext = extractor
        guard server != nil || ext != nil else { return }

        generation += 1
        let gen = generation
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            if Task.isCancelled { return }
            let image: CGImage?
            if let server {
                image = await server(seconds)
            } else if let ext {
                image = await ext.thumbnail(at: seconds, maxWidth: 320)
            } else {
                image = nil
            }
            guard let self else { return }
            if gen == self.generation { self.previewImage = image }
        }
    }

    /// Keep one frame warm at the current playback position so the first scrub
    /// frame is on screen instantly (card is gated on isScrubbing, so invisible
    /// during playback). Driven from currentTime while not scrubbing; throttled
    /// to ~keyframe spacing; shares the `generation` guard with update(fraction:).
    func warm(toSeconds seconds: Double) {
        guard enabled, seconds >= 0, (extractor != nil || serverThumbnail != nil) else { return }
        guard abs(seconds - lastWarmedSeconds) >= warmThresholdSeconds else { return }
        lastWarmedSeconds = seconds

        generation += 1
        let gen = generation
        loadTask?.cancel()
        let server = serverThumbnail
        let ext = extractor
        loadTask = Task { [weak self] in
            let image: CGImage?
            if let server {
                image = await server(seconds)
            } else if let ext {
                image = await ext.thumbnail(at: seconds, maxWidth: 320)
            } else {
                image = nil
            }
            guard let self, gen == self.generation else { return }
            self.previewImage = image
        }
    }

    /// Cancel any pending scrub load (commit/cancel/idle-hide). Intentionally
    /// KEEPS `previewImage` so the warm seed survives for the next scrub;
    /// reset() drops it at session teardown.
    func clear() {
        loadTask?.cancel()
        loadTask = nil
    }

    /// Full session teardown. Drops the extractor reference; PlayerViewModel
    /// owns the extractor's `shutdown()`.
    func reset() {
        // Bump generation so a task suspended in the thumbnail await can't
        // publish a previous-session frame after reset.
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        previewImage = nil
        extractor = nil
        liveThumbnail = nil
        serverThumbnail = nil
        enabled = false
        lastWarmedSeconds = -Double.infinity
    }
}
