import Foundation
import os.log

private let log = Logger(subsystem: "de.superuser404.Sodalite.TopShelf", category: "ResumeBar")

/// Produces cell artwork with the resume bar already drawn into it, cached as files in the shared
/// container. Strictly best-effort: anything that fails returns no URL for that item and the
/// caller keeps today's behaviour (remote URL plus the system's own `playbackProgress`), so the
/// shelf can never come out worse than before.
enum ResumeBarArtwork {

    /// The shelf cell is far narrower than the 1280px the app asks Jellyfin for. Decoding at cell
    /// scale keeps each image around a megabyte instead of ~3.7, which matters in an extension
    /// that already trips "-17102 decompressing image" when several cells decode at once.
    private static let maxPixelSize = 640

    /// Past this many cells the win is not worth the budget; the rest fall back. Counts only
    /// cells that actually get a bar, so a run of progress-less items cannot push the rest out.
    private static let maxCells = 16

    /// Bump whenever the drawing changes. It rides in the file name, so old artwork stops
    /// matching, gets swept, and re-renders; without it a look change is invisible on every cell
    /// whose progress and accent happen to be unchanged.
    private static let renderVersion = 2

    /// Whole-pass budget. Renders are serial, so one unreachable image must not eat the
    /// extension's time slice and leave the shelf empty.
    private static let deadline: TimeInterval = 6

    private static let requestTimeout: TimeInterval = 4

    /// Maps item id to a burned-in artwork file. Items missing from the result render the old way.
    static func prepare(items: [JellyfinItem],
                        session: SharedSession,
                        accent: UInt32) async -> [String: URL] {
        guard let directory = containerDirectory() else {
            log.notice("no shared container; resume bars disabled")
            return [:]
        }

        let started = Date()
        var result: [String: URL] = [:]
        var live: Set<String> = []

        // Filter before the cap: applying it to the raw list would let a stretch of items without
        // progress eat the whole budget and leave real resume cells unrendered.
        let candidates = items.filter { $0.topShelfProgress != nil }.prefix(maxCells)

        for item in candidates {
            guard let fraction = item.topShelfProgress,
                  let remote = item.topShelfImageURL(baseURL: session.baseURL, token: session.accessToken)
            else { continue }

            let name = fileName(itemID: item.id, remote: remote, fraction: fraction, accent: accent)
            let destination = directory.appendingPathComponent(name)
            live.insert(name)

            if FileManager.default.fileExists(atPath: destination.path) {
                result[item.id] = destination
                continue
            }

            guard Date().timeIntervalSince(started) < deadline else {
                log.notice("resume bar pass hit its deadline; \(candidates.count - result.count) cells fall back")
                break
            }

            if await write(remote: remote, to: destination, fraction: fraction, accent: accent) {
                result[item.id] = destination
            }
        }

        sweep(directory: directory, keeping: live)
        return result
    }

    // MARK: - Rendering

    private static func write(remote: URL,
                              to destination: URL,
                              fraction: Double,
                              accent: UInt32) async -> Bool {
        guard let source = await download(remote) else { return false }
        guard let rendered = ResumeBarRenderer.render(source: source,
                                                      fraction: fraction,
                                                      accent: accent,
                                                      maxPixelSize: maxPixelSize)
        else {
            log.error("render failed for \(destination.lastPathComponent, privacy: .public)")
            return false
        }
        do {
            try rendered.write(to: destination, options: .atomic)
            // The Top Shelf is drawn by the home screen, not by us. Group-container files are not
            // world-readable by default, so widen the mode; if the sandbox still refuses, the
            // caller's fallback covers it.
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: destination.path)
            return true
        } catch {
            log.error("write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            log.notice("artwork download failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Files

    /// The progress and the accent are part of the name on purpose. The home screen caches by
    /// URL, so rewriting the same path with new pixels leaves the old bar on screen.
    private static func fileName(itemID: String,
                                 remote: URL,
                                 fraction: Double,
                                 accent: UInt32) -> String {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        // The access token rides in the query and rotates; keying on it would invalidate every
        // file on each rotation. The image tag is the part that actually identifies the artwork.
        let tag = URLComponents(url: remote, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "tag" }?
            .value ?? "notag"
        return "bar\(renderVersion)-\(sanitized(itemID))-\(sanitized(tag))-\(percent)-\(String(format: "%06X", accent)).jpg"
    }

    private static func sanitized(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(48))
    }

    private static func containerDirectory() -> URL? {
        guard let base = TopShelfCachePolicy.directory() else { return nil }
        let directory = base.appendingPathComponent("ResumeBars", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Every pass rewrites the full set of names it needs, so anything else is a stale progress
    /// value, a stale accent, or an item that left the row. Without this the directory only grows.
    private static func sweep(directory: URL, keeping live: Set<String>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for entry in entries where !live.contains(entry) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }
}
