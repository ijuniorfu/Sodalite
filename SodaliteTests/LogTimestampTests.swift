import Foundation
import Testing
@testable import Sodalite

/// The stamp is a machine-readable field: it gets diffed against a Jellyfin server log, pasted into an
/// issue, fed to an AI. So these pin the exact bytes rather than "contains a date", and they pin the
/// cases a hand-rolled calendar gets wrong, since this one does not go through `DateFormatter`.
@Suite("Diagnostic log UTC stamp")
struct LogTimestampTests {

    /// Truth for the expected values: `ISO8601DateFormatter` with `.withInternetDateTime` and
    /// `.withFractionalSeconds`, pinned to UTC. A sweep of every 997th second from 1970 to 2100 agreed
    /// with it on all 4.1 million samples; these keep the interesting ones in the suite.
    @Test(
        "the stamp matches ISO-8601 UTC to the millisecond",
        arguments: [
            (0.0, "1970-01-01T00:00:00.000Z"),
            (1_756_386_191.482, "2025-08-28T13:03:11.482Z"),
            (951_782_400.0, "2000-02-29T00:00:00.000Z"),
            (1_709_164_800.0, "2024-02-29T00:00:00.000Z"),
            // 2100 is divisible by 4 and NOT a leap year, the case a naive leap rule gets wrong.
            (4_107_542_400.0, "2100-03-01T00:00:00.000Z"),
            (1_767_225_599.999, "2025-12-31T23:59:59.999Z"),
            (1_767_225_600.0, "2026-01-01T00:00:00.000Z"),
        ]
    )
    func knownInstants(epoch: Double, expected: String) {
        #expect(LogTimestamp.stamp(Date(timeIntervalSince1970: epoch)) == expected)
    }

    /// A stamp that changes length knocks the message column out of alignment for every row below it,
    /// which is the whole reason the log carries one.
    @Test("every stamp is exactly the advertised width")
    func fixedWidth() {
        for epoch in [0.0, -1.0, 1_756_386_191.482, 4_107_542_400.0, 253_402_300_799.0] {
            let stamp = LogTimestamp.stamp(Date(timeIntervalSince1970: epoch))
            #expect(stamp.count == LogTimestamp.width, "\(stamp) is \(stamp.count) characters")
        }
    }

    /// Sub-millisecond precision is rounded, not truncated: a moment at .4819 reads .482. The second has
    /// to follow the rounding across its own boundary, or the log would show 11.000 inside minute 03.
    @Test("sub-millisecond precision rounds, and carries into the second")
    func rounding() {
        #expect(LogTimestamp.stamp(Date(timeIntervalSince1970: 1_756_386_191.4819)) == "2025-08-28T13:03:11.482Z")
        #expect(LogTimestamp.stamp(Date(timeIntervalSince1970: 1_756_386_191.9996)) == "2025-08-28T13:03:12.000Z")
    }

    /// Not reachable from a live clock, reachable from a device whose date is unset and from a test.
    /// A truncating division would put a negative millisecond in the field and print garbage.
    @Test("a pre-epoch date walks backwards instead of going negative")
    func beforeEpoch() {
        #expect(LogTimestamp.stamp(Date(timeIntervalSince1970: -1)) == "1969-12-31T23:59:59.000Z")
        #expect(LogTimestamp.stamp(Date(timeIntervalSince1970: -0.25)) == "1969-12-31T23:59:59.750Z")
    }

    /// The funnel, not just the formatter: `note(_:)` has to put the stamp in front of the stored line,
    /// because the iOS Copy button joins exactly what the view renders.
    @Test("LogTap stores the stamp in front of a redacted line")
    @MainActor
    func tapPrefixesEveryLine() async throws {
        // Found by marker rather than by position: LogTap is a process-wide singleton and the suite runs
        // in parallel, so another test's line can land in the buffer between the note and the read.
        let marker = "LogTimestampTests-\(UUID().uuidString)"
        LogTap.shared.note("[\(marker)] segment 12 requested api_key=9f2c1ab34de5470fa1b6c8d90e7f2a11")

        var line: String?
        for _ in 0 ..< 50 where line == nil {
            try await Task.sleep(for: .milliseconds(20))
            line = LogTap.shared.lines.first { $0.contains(marker) }
        }

        let stamped = try #require(line, "the noted line never reached the buffer")
        #expect(stamped.hasSuffix("segment 12 requested api_key=<redacted>"))
        #expect(!stamped.contains("9f2c1ab34de5470fa1b6c8d90e7f2a11"))
        // A fixed offset for the message column is the whole point, so pin the shape, not just presence.
        #expect(stamped.dropFirst(LogTimestamp.width).hasPrefix("  ["))
        #expect(String(stamped.prefix(LogTimestamp.width)).hasSuffix("Z"))
    }
}
