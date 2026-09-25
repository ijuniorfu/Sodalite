import Foundation
import Testing
@testable import Sodalite

/// Audit 2026-09-25 DIAG-6. `importShelfLines` merged the Top Shelf extension's lines straight into
/// the in-memory ring, bypassing `note(_:)` (they already carry a stamp) but also, as a side effect,
/// the file sink. Once those lines rolled off the 300-line ring, they were gone for good even with
/// the persistent log on, in exactly the case (the extension runs while the app is backgrounded)
/// the sink exists to hold. `appendPreformattedLinesToFileSink` is the seam `importShelfLines` now
/// goes through; this exercises it directly, the same way `ShelfLogTests` stands in for the real
/// App Group container it would otherwise need.
@Suite(.serialized)
struct LogFileSinkImportedShelfLinesTests {

    private func readSink() -> String {
        guard let url = LogTap.fileSinkURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func settle() {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "test.settle").asyncAfter(deadline: .now() + 0.2) { done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }

    @Test("preformatted lines reach the file sink when it is armed")
    func preformattedLinesReachTheFileSinkWhenArmed() async throws {
        LogTap.fileSinkEnabled = true
        defer { LogTap.fileSinkEnabled = false }
        LogTap.startFileSink()
        settle()

        LogTap.appendPreformattedLinesToFileSink([
            "2026-01-01T00:00:00.000Z  [TopShelf ext/ResumeBar] one",
            "2026-01-01T00:00:01.000Z  [TopShelf ext/ResumeBar] two",
        ])
        settle()

        let contents = readSink()
        #expect(contents.contains("[TopShelf ext/ResumeBar] one"))
        #expect(contents.contains("[TopShelf ext/ResumeBar] two"))
    }

    @Test("preformatted lines are dropped when the sink is off")
    func preformattedLinesDroppedWhenSinkOff() async throws {
        LogTap.fileSinkEnabled = false

        LogTap.appendPreformattedLinesToFileSink([
            "2026-01-01T00:00:00.000Z  [TopShelf ext/ResumeBar] should not persist",
        ])
        settle()

        #expect(!readSink().contains("should not persist"))
    }
}
