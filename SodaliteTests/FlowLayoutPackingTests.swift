import Foundation
import Testing
@testable import Sodalite

@Suite("FlowLayout row packing")
struct FlowLayoutPackingTests {
    @Test("wraps when the next item exceeds max width")
    func wraps() {
        let rows = FlowLayout.packRows(widths: [50, 50, 50], spacing: 10, maxWidth: 130)
        #expect(rows == [[0, 1], [2]])
    }

    @Test("everything fits on one row")
    func oneRow() {
        let rows = FlowLayout.packRows(widths: [40, 40], spacing: 8, maxWidth: 500)
        #expect(rows == [[0, 1]])
    }

    @Test("an item wider than max still gets its own row (never dropped)")
    func oversizeItem() {
        let rows = FlowLayout.packRows(widths: [200], spacing: 8, maxWidth: 130)
        #expect(rows == [[0]])
    }

    @Test("no subviews yields no rows")
    func empty() {
        let rows = FlowLayout.packRows(widths: [], spacing: 8, maxWidth: 130)
        #expect(rows.isEmpty)
    }
}

/// The real iOS player icon-row metrics: 44pt tap targets, 20pt gaps, and the portrait chrome width
/// (screen width minus the 20pt margin per side that PlayerTouchControls.chromeContentWidth applies).
@Suite("FlowLayout balanced packing")
struct FlowLayoutBalancedPackingTests {
    private static let icon: CGFloat = 44
    private static let gap: CGFloat = 20
    private static let portrait16Pro: CGFloat = 362
    private static let portrait13Mini: CGFloat = 335
    private static let landscape: CGFloat = 874

    private static func icons(_ count: Int) -> [CGFloat] {
        Array(repeating: icon, count: count)
    }

    @Test("five icons still fit one portrait row, six do not")
    func portraitThreshold() {
        #expect(FlowLayout.packRows(widths: Self.icons(5), spacing: Self.gap, maxWidth: Self.portrait16Pro).count == 1)
        #expect(FlowLayout.packRows(widths: Self.icons(6), spacing: Self.gap, maxWidth: Self.portrait16Pro).count == 2)
        #expect(FlowLayout.packRows(widths: Self.icons(5), spacing: Self.gap, maxWidth: Self.portrait13Mini).count == 1)
        #expect(FlowLayout.packRows(widths: Self.icons(6), spacing: Self.gap, maxWidth: Self.portrait13Mini).count == 2)
    }

    @Test("landscape keeps every icon on one row")
    func landscapeOneRow() {
        #expect(FlowLayout.packRows(widths: Self.icons(8), spacing: Self.gap, maxWidth: Self.landscape).count == 1)
    }

    @Test("greedy packing is unchanged without the flag")
    func greedyUnchanged() {
        let rows = FlowLayout.packRows(widths: Self.icons(6), spacing: Self.gap, maxWidth: Self.portrait16Pro)
        #expect(rows.map(\.count) == [5, 1])
    }

    @Test("balanced split avoids a near-empty last row")
    func balancedSplits() {
        func counts(_ n: Int) -> [Int] {
            FlowLayout.packRows(widths: Self.icons(n), spacing: Self.gap,
                                maxWidth: Self.portrait16Pro, balanced: true).map(\.count)
        }
        #expect(counts(6) == [3, 3])
        #expect(counts(7) == [4, 3])
        #expect(counts(8) == [4, 4])
    }

    @Test("balanced leaves a single row alone")
    func balancedSingleRow() {
        let rows = FlowLayout.packRows(widths: Self.icons(5), spacing: Self.gap,
                                       maxWidth: Self.portrait16Pro, balanced: true)
        #expect(rows == [[0, 1, 2, 3, 4]])
    }

    @Test("balanced falls back to greedy when an even split would overflow")
    func balancedFallback() {
        let widths: [CGFloat] = [280, 40, 40, 40]
        let greedy = FlowLayout.packRows(widths: widths, spacing: 10, maxWidth: 300)
        let balanced = FlowLayout.packRows(widths: widths, spacing: 10, maxWidth: 300, balanced: true)
        #expect(greedy == [[0], [1, 2, 3]])
        #expect(balanced == greedy)
    }
}
