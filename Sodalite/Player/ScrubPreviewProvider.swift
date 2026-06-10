import Foundation
import CoreGraphics
import AetherEngine

/// Session-scoped scrub-preview source. Configured once per playback
/// session with the session's `FrameExtractor`, then driven by
/// `update(fraction:durationSeconds:)` as the user scrubs. Publishes a
/// ready-to-draw `CGImage` so the transport bar stays free of any
/// extraction detail. The extractor (owned by `PlayerViewModel`) handles
/// decode, caching, and cancel-on-supersede internally.
///
/// Fallback: extractor returns nil -> previewImage nil (transport bar
/// shows the time only).
@Observable
@MainActor
final class ScrubPreviewProvider {

    /// The frame to draw above the playhead. Nil means "no image, show
    /// time only".
    private(set) var previewImage: CGImage?

    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var extractor: FrameExtractor?
    /// Live mode: thumbnails come from the engine's DVR segment cache via
    /// this closure (seconds, maxWidth) instead of a session FrameExtractor.
    @ObservationIgnored private var liveThumbnail: ((Double, Int) async -> CGImage?)?

    // Debounce + staleness control.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    // Continuous warming: source seconds of the last frame we warmed to,
    // used to throttle re-extraction to roughly keyframe spacing.
    @ObservationIgnored private var lastWarmedSeconds = -Double.infinity
    @ObservationIgnored private let warmThresholdSeconds: Double = 2

    init() {}

    /// Set up for a new playback session. `enabled` reflects the user's
    /// Settings toggle; when false the provider does nothing. `extractor`
    /// is the session extractor (nil if the source URL couldn't be built).
    func configure(extractor: FrameExtractor?, enabled: Bool) {
        reset()
        self.extractor = extractor
        self.enabled = enabled
    }

    /// Set up for a live playback session. Mutually exclusive with
    /// `configure(extractor:enabled:)`; `reset()` clears both.
    func configureLive(enabled: Bool, thumbnail: @escaping (Double, Int) async -> CGImage?) {
        reset()
        self.liveThumbnail = thumbnail
        self.enabled = enabled
    }

    /// Live drive entry: absolute session-timeline seconds (the
    /// `liveSeekableRange` domain). The fraction-based `update` stays
    /// VOD-only; it needs a duration and live duration is 0. Shares the
    /// debounce and generation guard.
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
    /// cold-start latency. Safe to call repeatedly.
    func prewarm() {
        guard enabled, let extractor else { return }
        Task { await extractor.prewarm() }
    }

    /// Drive the preview to a scrub position. `fraction` is 0...1 of the
    /// runtime. Debounced so a fast swipe doesn't fire a decode per frame;
    /// the `generation` guard drops stale async results.
    func update(fraction: Float, durationSeconds: Double) {
        guard enabled, let extractor, durationSeconds > 0 else { return }
        let seconds = Double(max(0, min(1, fraction))) * durationSeconds

        generation += 1
        let gen = generation
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            if Task.isCancelled { return }
            let image = await extractor.thumbnail(at: seconds, maxWidth: 320)
            guard let self else { return }
            if gen == self.generation { self.previewImage = image }
        }
    }

    /// Keep one frame warm at the current *playback* position so the first
    /// scrub frame is already on screen the instant scrubbing begins (the
    /// transport card is gated on `isScrubbing`, so this image stays invisible
    /// during normal playback). Driven from `PlayerViewModel`'s currentTime
    /// stream while *not* scrubbing. No debounce (already low-frequency);
    /// throttled to ~keyframe spacing so we don't re-decode the same frame.
    /// Shares the `generation` guard with `update(fraction:)`, so a scrub
    /// always supersedes an in-flight warm and vice versa.
    func warm(toSeconds seconds: Double) {
        guard enabled, let extractor, seconds >= 0 else { return }
        guard abs(seconds - lastWarmedSeconds) >= warmThresholdSeconds else { return }
        lastWarmedSeconds = seconds

        generation += 1
        let gen = generation
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let image = await extractor.thumbnail(at: seconds, maxWidth: 320)
            guard let self, gen == self.generation else { return }
            self.previewImage = image
        }
    }

    /// Cancel any pending scrub load. Call on commit / cancel / idle-hide.
    /// Intentionally keeps `previewImage`: the warm seed survives so the next
    /// scrub shows a frame immediately, and the card is hidden between scrubs
    /// anyway. `reset()` drops the image at session teardown.
    func clear() {
        loadTask?.cancel()
        loadTask = nil
    }

    /// Full teardown for end of session. Drops the extractor reference;
    /// PlayerViewModel owns the extractor's `shutdown()`.
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        previewImage = nil
        extractor = nil
        liveThumbnail = nil
        enabled = false
        lastWarmedSeconds = -Double.infinity
    }
}
