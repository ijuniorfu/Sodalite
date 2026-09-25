import Foundation
import Testing
@testable import Sodalite

/// Audit 2026-09-25 DIAG-5. `environmentLine` on its own (SodaliteApp.init) is noted before
/// `fileSinkEnabled` is set, so it never reached the file: a persisted segment started at
/// "file sink armed" with no version or engine line, the AetherPlayer#7 failure mode
/// `environmentLine` exists to prevent. `startFileSink()` is the one choke point both the launch
/// path and the mid-session toggle go through, so it carries the line itself now.
@Suite(.serialized)
struct LogFileSinkEnvironmentLineTests {

    private func readSink() -> String {
        guard let url = LogTap.fileSinkURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func settle() {
        // The sink writes on its own queue; drain it before reading.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "test.settle").asyncAfter(deadline: .now() + 0.2) { done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }

    @Test("arming the sink writes the build/engine environment line into the marker")
    func armingWritesEnvironmentLine() async throws {
        LogTap.fileSinkEnabled = true
        defer { LogTap.fileSinkEnabled = false }

        LogTap.startFileSink()
        settle()

        let contents = readSink()
        #expect(contents.contains("file sink armed"))
        #expect(
            contents.contains(LogTap.environmentLine),
            "the armed marker did not carry the build/engine line: \(contents)"
        )
    }
}
