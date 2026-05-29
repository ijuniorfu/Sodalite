import Foundation
import UIKit

/// Session-scoped scrub-preview source. Configured once per playback
/// session with the item's trickplay manifest and chapter list, then
/// driven by `update(fraction:durationSeconds:)` as the user scrubs.
/// Publishes a ready-to-draw `CGImage` so the transport bar stays free
/// of any tile/geometry knowledge.
///
/// Fallback chain: trickplay tile (cropped) -> active chapter image ->
/// nil (transport bar shows the time only).
@Observable
@MainActor
final class ScrubPreviewProvider {

    /// The frame to draw above the playhead. Nil means "no image, show
    /// time only", which is the pre-trickplay behaviour.
    private(set) var previewImage: CGImage?

    @ObservationIgnored private let playbackService: JellyfinPlaybackServiceProtocol
    @ObservationIgnored private let session: URLSession

    // Per-session configuration.
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var itemID = ""
    @ObservationIgnored private var mediaSourceID = ""
    @ObservationIgnored private var geometry: TrickplayGeometry?
    @ObservationIgnored private var chapters: [ChapterInfo] = []

    // Decoded tile-sheet cache (keyed by sheet index) with simple LRU.
    @ObservationIgnored private var sheetCache: [Int: CGImage] = [:]
    @ObservationIgnored private var sheetOrder: [Int] = []
    @ObservationIgnored private let sheetCacheLimit = 6

    // Chapter-image cache (keyed by chapter index), small.
    @ObservationIgnored private var chapterCache: [Int: CGImage] = [:]

    // Debounce + staleness control.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(playbackService: JellyfinPlaybackServiceProtocol) {
        self.playbackService = playbackService
        // Dedicated short-lived session: trickplay sheets are large and
        // bursty, keep them out of the shared image pool's task retention.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        self.session = URLSession(configuration: config)
    }

    /// Set up for a new playback session. `enabled` reflects the user's
    /// Settings toggle; when false the provider does nothing.
    func configure(item: JellyfinItem, mediaSourceID: String, chapters: [ChapterInfo], enabled: Bool) {
        reset()
        self.enabled = enabled
        self.itemID = item.id
        self.mediaSourceID = mediaSourceID
        self.chapters = chapters
        self.geometry = TrickplayGeometry.best(from: item.trickplay, mediaSourceID: mediaSourceID)
    }

    /// Drive the preview to a scrub position. `fraction` is 0...1 of the
    /// runtime. Debounced so a fast swipe does not fire a load per frame.
    func update(fraction: Float, durationSeconds: Double) {
        guard enabled, durationSeconds > 0 else { return }
        let seconds = Double(max(0, min(1, fraction))) * durationSeconds

        generation += 1
        let gen = generation
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(60))
            if Task.isCancelled { return }
            await self.resolve(seconds: seconds, generation: gen)
        }
    }

    /// Clear the visible image but keep caches (cheap re-show on the next
    /// scrub in the same session). Call on commit / cancel / hide.
    func clear() {
        loadTask?.cancel()
        loadTask = nil
        previewImage = nil
    }

    /// Full teardown for end of session. Drops caches so sheets do not
    /// linger on the heap across videos.
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        previewImage = nil
        sheetCache.removeAll()
        sheetOrder.removeAll()
        chapterCache.removeAll()
        geometry = nil
        chapters = []
    }

    // MARK: - Resolution

    private func resolve(seconds: Double, generation gen: Int) async {
        if let geometry, geometry.isUsable {
            if let image = await trickplayImage(geometry: geometry, seconds: seconds, generation: gen) {
                if gen == generation { previewImage = image }
                return
            }
        }
        // Fallback: active chapter image.
        if let image = await chapterImage(seconds: seconds, generation: gen) {
            if gen == generation { previewImage = image }
            return
        }
        // Nothing available: time-only.
        if gen == generation { previewImage = nil }
    }

    // MARK: - Trickplay

    private func trickplayImage(geometry: TrickplayGeometry, seconds: Double, generation gen: Int) async -> CGImage? {
        let thumb = geometry.thumbnailIndex(forSeconds: seconds)
        let sheetIndex = geometry.sheetIndex(forThumbnail: thumb)
        let cropRect = geometry.cropRect(forThumbnail: thumb)

        guard let sheet = await sheet(at: sheetIndex, width: geometry.width, generation: gen) else { return nil }
        // Defensive: a malformed last sheet can be shorter than a full
        // grid; cropping outside bounds returns nil rather than crashing.
        let cropped = sheet.cropping(to: cropRect)

        // Warm the next sheet so forward scrubbing does not stall.
        let nextSheet = sheetIndex + 1
        if sheetCache[nextSheet] == nil {
            Task { [weak self] in _ = await self?.sheet(at: nextSheet, width: geometry.width, generation: gen) }
        }
        return cropped
    }

    private func sheet(at index: Int, width: Int, generation gen: Int) async -> CGImage? {
        if let cached = sheetCache[index] {
            touch(index)
            return cached
        }
        guard index >= 0,
              let url = playbackService.buildTrickplayURL(
                itemID: itemID, mediaSourceID: mediaSourceID, width: width, tileIndex: index
              )
        else { return nil }

        guard let data = try? await fetch(url), let cg = UIImage(data: data)?.cgImage else { return nil }
        if gen == generation || sheetCache[index] == nil {
            store(sheet: cg, at: index)
        }
        return cg
    }

    private func store(sheet: CGImage, at index: Int) {
        sheetCache[index] = sheet
        sheetOrder.removeAll { $0 == index }
        sheetOrder.append(index)
        while sheetOrder.count > sheetCacheLimit {
            let evict = sheetOrder.removeFirst()
            sheetCache[evict] = nil
        }
    }

    private func touch(_ index: Int) {
        sheetOrder.removeAll { $0 == index }
        sheetOrder.append(index)
    }

    // MARK: - Chapter fallback

    private func chapterImage(seconds: Double, generation gen: Int) async -> CGImage? {
        guard let chapterIndex = activeChapterIndex(forSeconds: seconds) else { return nil }
        if let cached = chapterCache[chapterIndex] { return cached }
        guard chapters.indices.contains(chapterIndex),
              let tag = chapters[chapterIndex].imageTag,
              let baseURL = playbackService.baseURL,
              let url = URL(string: "\(baseURL)/Items/\(itemID)/Images/Chapter/\(chapterIndex)?tag=\(tag)&maxWidth=480&quality=80")
        else { return nil }
        guard let data = try? await fetch(url), let cg = UIImage(data: data)?.cgImage else { return nil }
        chapterCache[chapterIndex] = cg
        return cg
    }

    /// Last chapter whose start is at or before `seconds`.
    private func activeChapterIndex(forSeconds seconds: Double) -> Int? {
        guard !chapters.isEmpty else { return nil }
        var idx: Int?
        for (i, chapter) in chapters.enumerated() {
            if chapter.startSeconds <= seconds + 0.001 { idx = i } else { break }
        }
        return idx
    }

    // MARK: - Networking

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
