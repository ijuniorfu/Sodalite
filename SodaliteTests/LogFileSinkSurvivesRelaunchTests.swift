import Foundation
import Testing
@testable import Sodalite

/// The sink exists to hold a transition that the 300-line memory ring rolls out, and the AE#597
/// repro spans an hour of sleep plus a look at other apps afterwards. tvOS can evict the app in
/// that window, so the launch that follows must not be the thing that destroys the evidence.
@Suite(.serialized)
struct LogFileSinkSurvivesRelaunchTests {

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

    @Test("a second launch keeps what the first one wrote")
    func relaunchKeepsEarlierLines() async throws {
        LogTap.fileSinkEnabled = true
        defer { LogTap.fileSinkEnabled = false }

        LogTap.startFileSink()
        LogTap.shared.note("[Test] the hour we cannot afford to lose")
        settle()
        #expect(readSink().contains("the hour we cannot afford to lose"))

        // The app is evicted and comes back: exactly what arming the sink again represents.
        LogTap.startFileSink()
        LogTap.shared.note("[Test] after the relaunch")
        settle()

        let contents = readSink()
        #expect(contents.contains("the hour we cannot afford to lose"),
                "the relaunch destroyed the session the sink exists to capture")
        #expect(contents.contains("after the relaunch"))
    }

    @Test("the file stays bounded across many launches")
    func repeatedLaunchesStayBounded() async throws {
        LogTap.fileSinkEnabled = true
        defer { LogTap.fileSinkEnabled = false }

        for _ in 0..<5 { LogTap.startFileSink() }
        LogTap.shared.note("[Test] still writing")
        settle()

        let url = try #require(LogTap.fileSinkURL)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(size <= LogTap.fileCapBytes, "the sink grew past its own cap")
        #expect(readSink().contains("still writing"))
    }
}
