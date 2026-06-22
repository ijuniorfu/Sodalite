import Foundation

/// Persistent stale-while-revalidate cache for home + catalog filter-tile result sets (three slices: homeFilterItems, smartFilterIDs, catalogPage). Backed by per-key JSON in `Library/Caches/FilterCache/`, NOT UserDefaults: tvOS caps CFPreferences at 1MB/domain and a populated provider tile (50+ JellyfinItem blobs) overflows it, SIGABRT inside `defaults.set` on first write. `@unchecked Sendable` safe (whole-file atomic IO, only the directory pointer is shared); synchronous so views can hydrate `@State` from `init()` in one render pass.
final class FilterCache: @unchecked Sendable {
    static let shared = FilterCache()

    private let directory: URL
    private static let homeItemsPrefix = "homeItems."
    private static let smartIDPrefix = "smart."
    private static let catalogPrefix = "catalog."

    // No timestamps (no expiry policy; refresh replaces wholesale); decode tolerates old files carrying a dropped `lastFetched`.
    private struct HomeItemsEntry: Codable {
        let items: [JellyfinItem]
    }

    private struct SmartEntry: Codable {
        let tmdbIDs: [Int]
    }

    struct CatalogEntry: Codable, Sendable {
        let items: [SeerrMedia]
        let totalPages: Int
    }

    init() {
        let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = caches.appendingPathComponent("FilterCache", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private func fileURL(for key: String) -> URL {
        // Keys embed server strings; a "/" ("Action/Adventure") becomes a path separator → write fails inside try? → permanent silent cache miss. Percent-encode outside a conservative set.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let safeKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        return directory.appendingPathComponent(safeKey).appendingPathExtension("json")
    }

    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, key: String) {
        let url = fileURL(for: key)
        guard let data = try? JSONEncoder().encode(value) else { return }
        // Atomic so a crash mid-flush keeps the prior file instead of a truncated blob that fails the next decode.
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Home Smart Filter (resolved JellyfinItems)

    func homeFilterItems(filterKey: String) -> [JellyfinItem]? {
        read(HomeItemsEntry.self, key: Self.homeItemsPrefix + filterKey)?.items
    }

    func setHomeFilterItems(_ items: [JellyfinItem], filterKey: String) {
        let entry = HomeItemsEntry(items: items)
        write(entry, key: Self.homeItemsPrefix + filterKey)
    }

    // MARK: - Smart Filter (TMDB ids)

    func smartFilterIDs(providerID: Int, region: String) -> [Int]? {
        read(SmartEntry.self, key: Self.smartIDPrefix + "\(providerID)-\(region)")?.tmdbIDs
    }

    func setSmartFilterIDs(_ ids: [Int], providerID: Int, region: String) {
        let entry = SmartEntry(tmdbIDs: ids)
        write(entry, key: Self.smartIDPrefix + "\(providerID)-\(region)")
    }

    // MARK: - Catalog Filter Page 1

    func catalogPage(filterKey: String) -> CatalogEntry? {
        read(CatalogEntry.self, key: Self.catalogPrefix + filterKey)
    }

    func setCatalogPage(_ items: [SeerrMedia], totalPages: Int, filterKey: String) {
        let entry = CatalogEntry(items: items, totalPages: totalPages)
        write(entry, key: Self.catalogPrefix + filterKey)
    }

    // MARK: - Bulk invalidation

    /// Clears every cache slice, called on profile switch / logout
    /// so a new user doesn't see the previous user's filter results.
    func clearAll() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for url in entries {
            try? FileManager.default.removeItem(at: url)
        }
    }

}
