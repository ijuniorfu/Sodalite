import SwiftUI
import UIKit

/// Authenticated, memory-cached AsyncImage replacement: attaches the Jellyfin `X-Emby-Token` header (stock AsyncImage can't inject headers, so auth-gated image endpoints 401), re-issues on URL change via `.task(id:)` (profile switch swaps the token), and keeps a memory-only cache (URLSession's disk cache can serve stale 401s across launches).
struct AsyncCachedImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// Second URL tried when the primary is nil or fails, e.g. a series Thumb falling back to backdrop/episode still.
    var fallbackURL: URL? = nil
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.dependencies) private var dependencies
    @State private var loaded: UIImage?

    var body: some View {
        ZStack {
            if let loaded {
                content(Image(uiImage: loaded))
                    .transition(.opacity.animation(.easeIn(duration: 0.2)))
            } else {
                placeholder()
            }
        }
        .task(id: "\(url?.absoluteString ?? "")|\(fallbackURL?.absoluteString ?? "")") {
            await load()
        }
    }

    @MainActor
    private func load() async {
        // Reset on URL change so a stale image from the previous profile doesn't flash while the new one loads.
        loaded = nil
        if let image = await loadImage(from: url) {
            loaded = image
            return
        }
        if let image = await loadImage(from: fallbackURL) {
            loaded = image
        }
    }

    @MainActor
    private func loadImage(from url: URL?) async -> UIImage? {
        guard let url else { return nil }

        if let cached = ImageCache.shared.image(for: url) {
            return cached
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

        let prepared = await Self.fetchAndDecode(request: request)
        guard let prepared else { return nil }
        // Cache before the cancellation check: a `.task(id:)` invalidation may cancel between decode and @State write, but the bytes are already in memory, so skipping the store would re-pay bandwidth+decode on next mount.
        ImageCache.shared.store(prepared, for: url)
        guard !Task.isCancelled else { return nil }
        return prepared
    }

    /// Network + decode + force-decompress off the MainActor. `preparingForDisplay()` runs the pixel decode now so the first draw isn't a scroll frame-drop; static + `nonisolated` keeps it on the cooperative pool. Cancellation propagates from the enclosing `.task(id:)`.
    nonisolated private static func fetchAndDecode(request: URLRequest) async -> UIImage? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = UIImage(data: data)
            else { return nil }
            return image.preparingForDisplay() ?? image
        } catch {
            return nil
        }
    }
}

extension AsyncCachedImage where Placeholder == ProgressView<EmptyView, EmptyView> {
    init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content) {
        self.url = url
        self.content = content
        self.placeholder = { ProgressView() }
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
