import AetherEngine
import Testing
@testable import Sodalite

/// The line that leads a handed-over log. Its whole job is to state the three facts a reader would
/// otherwise guess, and the engine version is the one that cannot be recovered afterwards: SwiftPM
/// pins a revision rather than a tag, so a report analysed without it gets the version supplied from
/// an older thread (AetherPlayer#7).
struct DiagnosticEnvironmentLineTests {

    @Test("the line names the engine release")
    func namesTheEngine() {
        #expect(LogTap.environmentLine.contains("AetherEngine \(AetherEngine.version)"))
    }

    @Test("the line names the app and the system it ran on")
    func namesTheAppAndSystem() {
        let line = LogTap.environmentLine
        #expect(line.hasPrefix("Sodalite "))
        #expect(line.contains("Version"))
    }

    /// It is pasted into an issue as one line, so a stray newline would break the quoting it is for.
    @Test("the line is a single line")
    func isOneLine() {
        #expect(!LogTap.environmentLine.contains("\n"))
    }
}
