import Foundation

/// Fonts an ASS track embeds, written out for libass under `Library/Caches/ass-fonts/<itemID>`.
///
/// Anime MKVs carry dozens of 5 to 20 MB faces, and every item used to leave its set behind for
/// good. Only the item on screen needs them: `activate` drops every other item's set, the end of a
/// session drops the whole directory, and Settings' Clear Cached Data does too (Sodalite#117).
nonisolated enum ASSFontCache {

    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ass-fonts", isDirectory: true)
    }

    /// Created on the way out. `lastPathComponent` so a hostile server itemID can't escape the
    /// cache dir; it passes ".." through (resolves one level up when appended), so that is treated
    /// like empty too.
    static func directory(itemID: String, root: URL = root) -> URL {
        let safeID = (itemID as NSString).lastPathComponent
        let dirName = (safeID.isEmpty || safeID == "..") ? "item" : safeID
        let dir = root.appendingPathComponent(dirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Removes every item's set except the one in `keep`.
    static func prune(keeping keep: URL, root: URL = root) {
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        let kept = keep.standardizedFileURL.lastPathComponent
        for dir in siblings where dir.standardizedFileURL.lastPathComponent != kept {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    static func removeAll(root: URL = root) {
        try? FileManager.default.removeItem(at: root)
    }

    static func diskUsage(root: URL = root) -> Int {
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total = 0
        for case let url as URL in files {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }
}
