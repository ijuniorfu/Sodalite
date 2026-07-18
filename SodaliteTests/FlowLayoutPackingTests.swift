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
