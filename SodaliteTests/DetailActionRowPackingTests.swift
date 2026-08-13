import Foundation
import Testing
@testable import Sodalite

/// The detail pages' action row used to scroll horizontally on compact widths, which hid the
/// per-series spoiler button off the right edge on the iPhone (Sodalite#50 follow-up). It wraps now,
/// so what matters is that the wrap keeps every button inside the content width.
///
/// Metrics are the collapsed pill (18pt padding per side around a body-size glyph, so ~56pt), the
/// row's 16pt spacing, and the content width of an iPhone in portrait and landscape after the
/// detail page's horizontal insets.
@Suite("Detail action row packing")
struct DetailActionRowPackingTests {
    private static let pill: CGFloat = 56
    private static let gap: CGFloat = 16
    private static let portrait: CGFloat = 360
    private static let landscape: CGFloat = 834
    /// The prominent Play button keeps its label, so it is far wider than a collapsed pill.
    private static let play: CGFloat = 150

    private static func pills(_ count: Int) -> [CGFloat] {
        Array(repeating: pill, count: count)
    }

    private static func widest(_ rows: [[Int]], _ widths: [CGFloat]) -> CGFloat {
        rows.map { row in
            row.map { widths[$0] }.reduce(0, +) + gap * CGFloat(max(0, row.count - 1))
        }.max() ?? 0
    }

    @Test("a series with every action fits two portrait rows, none of them overflowing")
    func seriesFitsTwoRows() {
        // Shuffle, replay, trailer, favorite, watched, spoiler: the fullest secondary row there is.
        let widths = Self.pills(6)
        let rows = FlowLayout.packRows(widths: widths, spacing: Self.gap,
                                       maxWidth: Self.portrait, balanced: true)
        #expect(rows.map(\.count) == [3, 3])
        #expect(Self.widest(rows, widths) <= Self.portrait)
    }

    @Test("the common four-button series still needs one portrait row")
    func fourButtonsStayOnOneRow() {
        let widths = Self.pills(4)
        let rows = FlowLayout.packRows(widths: widths, spacing: Self.gap,
                                       maxWidth: Self.portrait, balanced: true)
        #expect(rows.count == 1)
        #expect(Self.widest(rows, widths) <= Self.portrait)
    }

    @Test("two more buttons than today still fit inside the width")
    func headroomForFutureButtons() {
        let widths = Self.pills(8)
        let rows = FlowLayout.packRows(widths: widths, spacing: Self.gap,
                                       maxWidth: Self.portrait, balanced: true)
        #expect(rows.map(\.count) == [4, 4])
        #expect(Self.widest(rows, widths) <= Self.portrait)
    }

    @Test("landscape keeps play and every secondary button on one row")
    func landscapeStaysOneRow() {
        let widths = [Self.play] + Self.pills(6)
        let rows = FlowLayout.packRows(widths: widths, spacing: Self.gap, maxWidth: Self.landscape)
        #expect(rows.count == 1)
        #expect(Self.widest(rows, widths) <= Self.landscape)
    }
}
