import Foundation

/// Where the shelf's offline fallback lives and when it may be used. Shared between the
/// extension (which writes and reads it) and the app (which deletes it on logout), so neither
/// hand-rolls the container path. `nonisolated` throughout: the app targets default to
/// MainActor isolation, the extension does not.
enum TopShelfCachePolicy {
    nonisolated static let appGroup = "group.de.superuser404.Sodalite"
    nonisolated static let fileName = "topshelf-cache.json"

    /// tvOS only lets an app write under `Library/Caches` and `Library/Preferences`; the root of
    /// the group container is read-only, and the refusal arrives as a thrown error that every
    /// call site here swallowed. A device listing of the container showed those two directories
    /// and nothing else, so this cache never once landed. Anything written here is expendable by
    /// definition, which is what Caches is for.
    nonisolated static func directory() -> URL? {
        guard let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return nil }
        return base.appendingPathComponent("Library/Caches", isDirectory: true)
    }

    nonisolated static func fileURL() -> URL? {
        directory()?.appendingPathComponent(fileName)
    }

    /// The whole staleness policy. A cache only outlives its usefulness when the session
    /// changes, and this catches exactly that, so there is no TTL.
    nonisolated static func matches(cachedServerURL: String,
                                    cachedUserID: String,
                                    sessionServerURL: String,
                                    sessionUserID: String) -> Bool {
        cachedUserID == sessionUserID
            && normalized(cachedServerURL) == normalized(sessionServerURL)
    }

    /// A run where both fetches threw must not replace a good cache with two empty arrays;
    /// that is the exact situation the cache exists for.
    nonisolated static func shouldWrite(resumeSucceeded: Bool, nextUpSucceeded: Bool) -> Bool {
        resumeSucceeded || nextUpSucceeded
    }

    nonisolated static func delete() {
        guard let url = fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated private static func normalized(_ urlString: String) -> String {
        var value = urlString
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
