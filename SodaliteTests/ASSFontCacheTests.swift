import Testing
import Foundation
@testable import Sodalite

/// Every item with an embedded-font ASS track used to leave its fonts under Caches for good, and the
/// Settings screen that claims to count and clear every cache did neither. Audit 2026-09-25
/// PLAYER-PERIPHERY-2.
struct ASSFontCacheTests {

    private func scratchRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ass-fonts-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeFont(_ name: String, bytes: Int, in dir: URL) throws {
        try Data(repeating: 0x41, count: bytes).write(to: dir.appendingPathComponent(name))
    }

    @Test func activatingAnItemDropsEveryOtherItemsFonts() throws {
        let root = scratchRoot()
        defer { ASSFontCache.removeAll(root: root) }
        let old = ASSFontCache.directory(itemID: "item-old", root: root)
        try writeFont("a.ttf", bytes: 100, in: old)
        let current = ASSFontCache.directory(itemID: "item-now", root: root)
        try writeFont("b.ttf", bytes: 50, in: current)

        ASSFontCache.prune(keeping: current, root: root)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("b.ttf").path))
        #expect(ASSFontCache.diskUsage(root: root) == 50)
    }

    @Test func removingAllLeavesNothingToCount() throws {
        let root = scratchRoot()
        let dir = ASSFontCache.directory(itemID: "item", root: root)
        try writeFont("a.ttf", bytes: 10, in: dir)
        #expect(ASSFontCache.diskUsage(root: root) == 10)

        ASSFontCache.removeAll(root: root)
        #expect(ASSFontCache.diskUsage(root: root) == 0)
    }

    @Test func aHostileItemIDStaysInsideTheCache() {
        let root = scratchRoot()
        defer { ASSFontCache.removeAll(root: root) }
        #expect(ASSFontCache.directory(itemID: "..", root: root).deletingLastPathComponent().standardizedFileURL
                == root.standardizedFileURL)
        #expect(ASSFontCache.directory(itemID: "../../etc", root: root).deletingLastPathComponent().standardizedFileURL
                == root.standardizedFileURL)
    }

    @Test func leftoverFontsArmTheClearButton() {
        #expect(!CacheFootprint(feedAndLists: 0, serverResponses: 0, artwork: 0, subtitleFonts: 1).isEmpty)
    }
}
