import SwiftUI
import UIKit

/// Authenticated, memory-cached AsyncImage replacement: attaches the Jellyfin `X-Emby-Token` header (stock AsyncImage can't inject headers, so auth-gated image endpoints 401), re-issues on URL change via `.task(id:)` (profile switch swaps the token), and keeps a memory-only cache (URLSession's disk cache can serve stale 401s across launches).
struct AsyncCachedImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// Second URL tried when the primary is nil or fails, e.g. a series Thumb falling back to backdrop/episode still.
    var fallbackURL: URL? = nil
    /// Fires with the decoded image whenever one lands, cache hit included, so a caller can derive
    /// artwork colours (ArtworkTint) without decoding the bytes a second time.
    var onImageLoaded: ((UIImage) -> Void)? = nil
    /// Fires false when a load starts and true once every candidate has failed. The placeholder is
    /// also what shows WHILE loading, so a caller that deliberately blanks its placeholder (the
    /// detail-page logo reserving its slot, Sodalite#97) can only tell "still coming" from "never
    /// coming" here, and put its own fallback back.
    var onLoadFailed: ((Bool) -> Void)? = nil
    /// Built with the decoded image AND that image's own size, so a caller that has to size its
    /// frame from the source's aspect ratio reads both out of the same state. Handing the size back
    /// through `onImageLoaded` instead puts it in the CALLER's state, one view up, where the image
    /// can render a pass before the aspect arrives: the detail-page logo drew every first open
    /// square that way (Sodalite#97).
    let content: (Image, CGSize) -> Content
    let placeholder: () -> Placeholder

    init(
        url: URL?,
        fallbackURL: URL? = nil,
        onImageLoaded: ((UIImage) -> Void)? = nil,
        onLoadFailed: ((Bool) -> Void)? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(
            url: url,
            fallbackURL: fallbackURL,
            onImageLoaded: onImageLoaded,
            onLoadFailed: onLoadFailed,
            sizedContent: { image, _ in content(image) },
            placeholder: placeholder
        )
    }

    init(
        url: URL?,
        fallbackURL: URL? = nil,
        onImageLoaded: ((UIImage) -> Void)? = nil,
        onLoadFailed: ((Bool) -> Void)? = nil,
        @ViewBuilder sizedContent: @escaping (Image, CGSize) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.onImageLoaded = onImageLoaded
        self.onLoadFailed = onLoadFailed
        self.content = sizedContent
        self.placeholder = placeholder
    }

    @Environment(\.dependencies) private var dependencies
    @Environment(\.scenePhase) private var scenePhase
    @State private var loaded: UIImage?
    /// Connection-level failures (offline blip, iOS local-network permission prompt
    /// still unanswered) must not latch the placeholder forever. Retry on the next
    /// scene activation: a dismissed permission alert flips the phase back to active.
    @State private var retryOnActivate = false

    var body: some View {
        ZStack {
            if let loaded {
                content(Image(uiImage: loaded), loaded.size)
                    .transition(.opacity.animation(.easeIn(duration: 0.25)))
                    // Above the placeholder for the length of the swap, which is what lets the
                    // placeholder stay opaque underneath instead of having to fade in step.
                    .zIndex(1)
            } else {
                placeholder()
                    // The image faded IN and the placeholder was removed with no transition at all,
                    // so between the two there was a gap where neither was drawn: every artwork on
                    // the page appeared to pop out and then fade back (Sodalite discussion #98,
                    // point 3). It now holds full strength until the image above it is opaque, and
                    // lets go behind it, so nothing ever uncovers what is behind them both.
                    .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.25)))
                    .zIndex(0)
            }
        }
        .task(id: "\(url?.absoluteString ?? "")|\(fallbackURL?.absoluteString ?? "")") {
            await load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, retryOnActivate, loaded == nil {
                Task { await load() }
            }
        }
    }

    @MainActor
    private func load() async {
        // Reset on URL change so a stale image from the previous profile doesn't flash while the new one loads.
        loaded = nil
        retryOnActivate = false
        onLoadFailed?(false)
        var sawTransientFailure = false
        for candidate in [url, fallbackURL] {
            let result = await loadImage(from: candidate)
            if let image = result.image {
                loaded = image
                onImageLoaded?(image)
                return
            }
            sawTransientFailure = sawTransientFailure || result.transientFailure
        }
        retryOnActivate = sawTransientFailure
        onLoadFailed?(true)
    }

    @MainActor
    private func loadImage(from url: URL?) async -> (image: UIImage?, transientFailure: Bool) {
        guard let url else { return (nil, false) }

        if let cached = ImageCache.shared.image(for: url) {
            return (cached, false)
        }

        // Request built on MainActor to read the MainActor-isolated token; attach auth only for the active Jellyfin host so external URLs (TMDB/CDN posters) don't see our token.
        var request = URLRequest(url: url)
        // 15s, not the 60s default: one hanging poster otherwise holds the row in placeholder for a full minute.
        request.timeoutInterval = 15
        if url.host == dependencies.jellyfinClient.baseURL?.host,
           let token = dependencies.jellyfinClient.accessToken,
           !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }

        let result = await Self.fetchAndDecode(request: request)
        guard let prepared = result.image else { return (nil, result.transientFailure) }
        // Cache before the cancellation check: a `.task(id:)` invalidation may cancel between decode and @State write, but the bytes are already in memory, so skipping the store would re-pay bandwidth+decode on next mount.
        ImageCache.shared.store(prepared, for: url)
        guard !Task.isCancelled else { return (nil, false) }
        return (prepared, false)
    }

    /// Network + decode + force-decompress off the MainActor. `preparingForDisplay()` runs the pixel decode now so the first draw isn't a scroll frame-drop; static + `nonisolated` keeps it on the cooperative pool. Cancellation propagates from the enclosing `.task(id:)`.
    /// transientFailure marks connection-level errors (worth retrying on scene activation), never HTTP errors or undecodable payloads.
    nonisolated private static func fetchAndDecode(request: URLRequest) async -> (image: UIImage?, transientFailure: Bool) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = UIImage(data: data)
            else { return (nil, false) }
            return (image.preparingForDisplay() ?? image, false)
        } catch is CancellationError {
            return (nil, false)
        } catch let error as URLError where error.code == .cancelled {
            return (nil, false)
        } catch {
            LogTap.shared.note("[Image] fetch failed \(request.url?.absoluteString ?? ""): \(error)")
            return (nil, true)
        }
    }
}

extension AsyncCachedImage where Placeholder == ProgressView<EmptyView, EmptyView> {
    init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content) {
        self.init(url: url, content: content, placeholder: { ProgressView() })
    }
}

// MARK: - Cache

final class ImageCache: @unchecked Sendable {
    // Plain `nonisolated` (not `(unsafe)`): Sendable constant reachable from background prefetch under the project's MainActor default isolation.
    nonisolated static let shared = ImageCache()

    // `nonisolated(unsafe)`: NSCache is thread-safe, so prefetch can `store` from background tasks without a per-image MainActor hop.
    nonisolated(unsafe) private let cache: NSCache<NSURL, UIImage>

    /// Cost-based eviction by decoded byte size; the 150 MB budget gates (countLimit stays generous), bounded so long sessions don't grow into hundreds of MB.
    nonisolated private init() {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 150_000_000
        cache.countLimit = 1000
        self.cache = cache
    }

    // nonisolated so the prefetch hot path stores from off-actor tasks without a per-image MainActor hop (NSCache is thread-safe).
    nonisolated func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    nonisolated func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: estimatedBytes(for: image))
    }

    /// Wipe on profile switches: a poster cached with user A's token may be unfetchable under user B's permissions.
    func clear() {
        cache.removeAllObjects()
    }

    /// Decoded size estimate: width × height × scale² × 4 bytes (RGBA8). Ignores HDR/wide-gamut backing, fine as an NSCache cost signal.
    nonisolated private func estimatedBytes(for image: UIImage) -> Int {
        let scale = image.scale
        let pixels = image.size.width * scale * image.size.height * scale
        return Int(pixels) * 4
    }
}

// MARK: - Prefetch

extension ImageCache {
    /// Background batch cache-warm: skips cached URLs, fans out the rest with bounded concurrency, drops failures silently. `authToken`/`jellyfinHost` mirror `load`: X-Emby-Token only for the active Jellyfin host so external CDN URLs don't leak the token.
    static func prefetch(
        _ urls: [URL],
        authToken: String?,
        jellyfinHost: String?
    ) async {
        let pending = urls.filter { ImageCache.shared.image(for: $0) == nil }
        guard !pending.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            // 6 in flight: saturates a home LAN without crowding foreground fetches; matches URLSession's per-host default.
            let maxConcurrent = 6
            var iter = pending.makeIterator()

            for _ in 0..<min(maxConcurrent, pending.count) {
                guard let url = iter.next() else { break }
                group.addTask {
                    await prefetchOne(url: url, token: authToken, jfHost: jellyfinHost)
                }
            }
            for await _ in group {
                if let url = iter.next() {
                    group.addTask {
                        await prefetchOne(url: url, token: authToken, jfHost: jellyfinHost)
                    }
                }
            }
        }
    }

    nonisolated private static func prefetchOne(
        url: URL,
        token: String?,
        jfHost: String?
    ) async {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let token, !token.isEmpty, url.host == jfHost {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = UIImage(data: data)
            else { return }
            let prepared = image.preparingForDisplay() ?? image
            ImageCache.shared.store(prepared, for: url)
        } catch {
            // Best-effort: on failure the AsyncCachedImage pays the round-trip itself on first focus.
        }
    }
}
