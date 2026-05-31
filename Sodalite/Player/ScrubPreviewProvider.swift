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

    // Debounce + staleness control.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init() {}

    /// Set up for a new playback session. `enabled` reflects the user's
    /// Settings toggle; when false the provider does nothing. `extractor`
    /// is the session extractor (nil if the source URL couldn't be built).
    func configure(extractor: FrameExtractor?, enabled: Bool) {
        reset()
        self.extractor = extractor
        self.enabled = enabled
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

    /// Clear the visible image but keep the extractor (cheap re-show on the
    /// next scrub). Call on commit / cancel / hide.
    func clear() {
        loadTask?.cancel()
        loadTask = nil
        previewImage = nil
    }

    /// Full teardown for end of session. Drops the extractor reference;
    /// PlayerViewModel owns the extractor's `shutdown()`.
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        previewImage = nil
        extractor = nil
        enabled = false
    }
}
