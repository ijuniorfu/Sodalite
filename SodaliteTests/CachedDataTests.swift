import Testing
import Foundation
@testable import Sodalite

/// Sodalite#117, DrHurt: "might be worth adding a cache tab in settings to allow monitoring and
/// clearing cache in case it gets corrupted or causes issues".
///
/// A button that says it clears the cache has to clear all of it, and a number next to it has to be
/// the number of bytes that are actually there. These pin both, plus the thing that rots first: a
/// cache added later that nobody remembers to wire into either.
@MainActor
struct CachedDataTests {

    // MARK: - What is on disk

    /// The feed and tile entries are the one store Sodalite writes itself, so its size is the one
    /// figure that is ours to get right rather than Apple's to report.
    @Test("the entry cache reports the bytes its files occupy, and nothing once cleared")
    func filterCacheReportsItsFootprint() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cache-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = FilterCache(directory: directory)
        #expect(cache.diskUsage() == 0, "an empty cache occupies nothing")

        let identity = CacheIdentity(serverID: "s1", userID: "u1")
        cache.setHomeFeed(
            [HomeRowData(type: .continueWatching, items: [
                JellyfinItem(seriesStub: "m1", name: "A film with a name long enough to weigh something")
            ])],
            libraries: [],
            identity: identity
        )

        let written = cache.diskUsage()
        #expect(written > 0, "a written entry has to show up as bytes")
        #expect(written == Self.bytesOnDisk(in: directory), "the figure is not the sum of the files")

        cache.clearAll()
        #expect(cache.diskUsage() == 0, "cleared entries are still counted")
    }

    /// A directory that is not there yet (first launch, or right after a clear on some filesystems)
    /// reports nothing rather than failing the screen that asks.
    @Test("a cache directory that does not exist reports no bytes")
    func missingDirectoryIsEmptyNotAnError() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cache-missing-\(UUID().uuidString)", isDirectory: true)
        let cache = FilterCache(directory: directory)
        try? FileManager.default.removeItem(at: directory)
        #expect(cache.diskUsage() == 0)
    }

    // MARK: - What the screen adds up

    @Test("the footprint totals its three parts and knows when there is nothing to clear")
    func footprintTotals() {
        let footprint = CacheFootprint(feedAndLists: 43_000, serverResponses: 12_400_000, artwork: 31_800_000)
        #expect(footprint.total == 44_243_000)
        #expect(!footprint.isEmpty)
        #expect(CacheFootprint(feedAndLists: 0, serverResponses: 0, artwork: 0).isEmpty)
    }

    // MARK: - The rule that rots

    /// Every response cache in the app is a `URLCache` built with a `diskPath`, and each one has to
    /// be reachable from the single button that clears them. A fourth cache added later is exactly
    /// the kind of thing that gets a constructor and no wiring, and then the button quietly stops
    /// telling the truth. So the sources are the checklist.
    ///
    /// Two clients share `sodalite-http-cache` on purpose (Jellyfin and Seerr each build their own
    /// `URLCache` over the same directory), which is why the paths are compared as a SET: the
    /// footprint reads that store once, and clearing walks every client that holds a handle on it.
    @Test("every URLCache in the app is named by the screen that clears it")
    func everyDiskCacheIsWiredIntoTheClearButton() throws {
        var declared: Set<String> = []
        for file in try Self.swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                guard line.contains("diskPath:") else { continue }
                guard let path = Self.quotedValue(after: "diskPath:", in: String(line)) else { continue }
                declared.insert(path)
            }
        }

        #expect(!declared.isEmpty, "the scan found no URLCache at all, so it is not reading the sources")

        let wiring = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Sodalite/App/Environment/DependencyContainer+Caches.swift"),
            encoding: .utf8
        )
        let unwired = declared.filter { !wiring.contains($0) }
        #expect(
            unwired.isEmpty,
            """
            These response caches exist but are not named in DependencyContainer+Caches.swift, so \
            Settings neither counts nor clears them: \(unwired.sorted().joined(separator: ", "))
            """
        )
    }

    // MARK: - Helpers

    private static func bytesOnDisk(in directory: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Audit 2026-09-25 SESSION-5: the shelf's items and rendered artwork outlived Log Out and a
    /// reset in the group container. Log Out keeps only the shelf's own log.
    @Test func theGroupCachesGoExceptWhatIsKept() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("groupCaches-\(UUID().uuidString)", isDirectory: true)
        let bars = directory.appendingPathComponent("ResumeBars", isDirectory: true)
        try FileManager.default.createDirectory(at: bars, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: bars.appendingPathComponent("item-50.jpg"))
        try Data("items".utf8).write(to: directory.appendingPathComponent("topshelf-cache.json"))
        try Data("log".utf8).write(to: directory.appendingPathComponent(ShelfLogFile.fileName))
        defer { try? FileManager.default.removeItem(at: directory) }

        DependencyContainer.clearGroupCaches(in: directory, keeping: [ShelfLogFile.fileName])

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left == [ShelfLogFile.fileName])
    }

    private static func quotedValue(after label: String, in line: String) -> String? {
        guard let labelRange = line.range(of: label) else { return nil }
        let rest = line[labelRange.upperBound...]
        guard let open = rest.firstIndex(of: "\"") else { return nil }
        let afterOpen = rest.index(after: open)
        guard let close = rest[afterOpen...].firstIndex(of: "\"") else { return nil }
        return String(rest[afterOpen..<close])
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func swiftSources() throws -> [URL] {
        let root = repositoryRoot().appendingPathComponent("Sodalite")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
