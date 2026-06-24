import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// Characterizes SRT/WebVTT parsing, including the non-finite timestamp guard (commit 8da3bddd).
@MainActor
struct SRTParserTests {
    private func text(_ cue: SubtitleCue?) -> String? {
        guard let cue, case .text(let body) = cue.body else { return nil }
        return body
    }

    @Test func parsesBasicSRTBlock() {
        let cues = SRTParser.parse("1\n00:00:01,000 --> 00:00:02,000\nHello")
        #expect(cues.count == 1)
        #expect(cues[0].startTime == 1.0)
        #expect(cues[0].endTime == 2.0)
        #expect(text(cues[0]) == "Hello")
    }

    @Test func stripsHTMLTags() {
        let cues = SRTParser.parse("1\n00:00:01,000 --> 00:00:02,000\n<i>Hi</i> <b>there</b>")
        #expect(text(cues.first) == "Hi there")
    }

    @Test func skipsWebVTTHeaderBlock() {
        let content = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nCaption"
        let cues = SRTParser.parse(content)
        #expect(cues.count == 1)
        #expect(text(cues[0]) == "Caption")
    }

    @Test func parsesMMSSTimestamp() {
        let cues = SRTParser.parse("00:01.500 --> 00:02.000\nShort")
        #expect(cues.count == 1)
        #expect(cues[0].startTime == 1.5)
    }

    @Test func dropsBlockWithNonFiniteTimestamp() {
        // A huge mantissa overflows Double to inf; the guard must drop that block, not admit an Inf endTime.
        let content = "1e400:00:00,000 --> 00:00:05,000\nBad\n\n00:00:03,000 --> 00:00:04,000\nGood"
        let cues = SRTParser.parse(content)
        #expect(cues.count == 1)
        #expect(text(cues[0]) == "Good")
    }

    @Test func dropsBlockWithEmptyText() {
        let cues = SRTParser.parse("00:00:01,000 --> 00:00:02,000\n   ")
        #expect(cues.isEmpty)
    }

    @Test func sortsCuesByStartTime() {
        let content = "00:00:05,000 --> 00:00:06,000\nSecond\n\n00:00:01,000 --> 00:00:02,000\nFirst"
        let cues = SRTParser.parse(content)
        #expect(cues.map { self.text($0) } == ["First", "Second"])
    }
}
