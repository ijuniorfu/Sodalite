import Foundation
import Testing
@testable import Sodalite

/// The Top Shelf's lines reach Settings > Diagnostic Log through a file the extension writes and the app
/// drains. These pin what crosses that file: whole stamped lines, handed over once, capped without
/// cutting a line in half, and merged into the buffer in time order.
@Suite("Top Shelf log bridge")
struct ShelfLogTests {

    private func temporaryFile() -> ShelfLogFile {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfLogTests-\(UUID().uuidString)", isDirectory: true)
        return ShelfLogFile(url: directory.appendingPathComponent(ShelfLogFile.fileName))
    }

    @Test("a drained line carries the stamp of the moment it was written")
    func drainReturnsStampedLines() {
        let file = temporaryFile()
        let first = Date(timeIntervalSince1970: 1_767_225_600)
        file.append("[TopShelf ext/ResumeBar] one", at: first)
        file.append("[TopShelf ext/ResumeBar] two", at: first.addingTimeInterval(1))

        #expect(file.drain() == [
            "2026-01-01T00:00:00.000Z  [TopShelf ext/ResumeBar] one",
            "2026-01-01T00:00:01.000Z  [TopShelf ext/ResumeBar] two",
        ])
    }

    @Test("a line is handed over once")
    func drainEmptiesTheFile() {
        let file = temporaryFile()
        file.append("line")
        #expect(file.drain().count == 1)
        #expect(file.drain().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test("the file stays under its cap and keeps whole, newest lines")
    func capKeepsNewestWholeLines() throws {
        let file = temporaryFile()
        let count = 1_200
        for index in 0 ..< count {
            file.append("[TopShelf ext/ContentProvider] line \(index)")
        }

        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int)
        #expect(size <= ShelfLogFile.capBytes)

        let lines = file.drain()
        #expect(lines.last?.hasSuffix("line \(count - 1)") == true)
        #expect(lines.allSatisfy { $0.hasPrefix("20") && $0.contains("  [TopShelf ext/ContentProvider] line ") })
    }

    @Test("the prefix names the process that wrote the line")
    func prefixNamesProcess() {
        #expect(ShelfLog.line(category: "ResumeBar", message: "m", inApp: true) == "[TopShelf app/ResumeBar] m")
        #expect(ShelfLog.line(category: "ResumeBar", message: "m", inApp: false) == "[TopShelf ext/ResumeBar] m")
    }

    @Test("imported lines land between the buffer's own by stamp")
    func mergeInterleavesByStamp() {
        let merged = LogTap.merged(
            ["2026-01-01T00:00:00.000Z  app a", "2026-01-01T00:00:02.000Z  app b"],
            ["2026-01-01T00:00:01.000Z  ext a", "2026-01-01T00:00:03.000Z  ext b"],
            limit: 10
        )
        #expect(merged == [
            "2026-01-01T00:00:00.000Z  app a",
            "2026-01-01T00:00:01.000Z  ext a",
            "2026-01-01T00:00:02.000Z  app b",
            "2026-01-01T00:00:03.000Z  ext b",
        ])
    }

    @Test("a tie keeps the buffer's line first, and the limit drops the oldest")
    func mergeTieAndLimit() {
        let merged = LogTap.merged(
            ["2026-01-01T00:00:01.000Z  app"],
            ["2026-01-01T00:00:00.000Z  ext old", "2026-01-01T00:00:01.000Z  ext tie"],
            limit: 2
        )
        #expect(merged == ["2026-01-01T00:00:01.000Z  app", "2026-01-01T00:00:01.000Z  ext tie"])
    }
}
