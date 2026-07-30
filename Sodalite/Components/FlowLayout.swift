import SwiftUI

enum FlowAlignment {
    case leading
    case center
}

/// Wrapping row layout: children flow left to right and wrap to a new row when
/// they would exceed the proposed width. `.leading` starts each row at the left
/// edge; `.center` centers each row. Shared by the appearance accent swatches
/// (center) and the server-row badge chips (leading).
struct FlowLayout: Layout {
    var alignment: FlowAlignment = .leading
    var spacing: CGFloat = 8
    /// Spread items evenly across the rows the greedy pack needed. Off by default so the existing
    /// consumers keep their left-to-right fill.
    var balanced: Bool = false

    static func packRows(widths: [CGFloat], spacing: CGFloat, maxWidth: CGFloat,
                         balanced: Bool = false) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var x: CGFloat = 0
        for (index, w) in widths.enumerated() {
            if !current.isEmpty, x + w > maxWidth {
                rows.append(current)
                current = []
                x = 0
            }
            current.append(index)
            x += w + spacing
        }
        if !current.isEmpty { rows.append(current) }
        guard balanced, rows.count > 1 else { return rows }
        return balancedRows(count: widths.count, rowCount: rows.count, widths: widths,
                            spacing: spacing, maxWidth: maxWidth) ?? rows
    }

    /// Even split across the row count greedy already proved sufficient, so a wrap never leaves a
    /// near-empty last row (six equal items in a five-wide space read as 3+3, not 5+1). Equal widths
    /// always fit, unequal ones may not, so an overflowing split returns nil and the caller keeps greedy.
    private static func balancedRows(count: Int, rowCount: Int, widths: [CGFloat],
                                     spacing: CGFloat, maxWidth: CGFloat) -> [[Int]]? {
        var result: [[Int]] = []
        var start = 0
        for row in 0..<rowCount {
            let remaining = rowCount - row
            let take = (count - start + remaining - 1) / remaining
            let slice = Array(start..<(start + take))
            let width = slice.map { widths[$0] }.reduce(0, +) + spacing * CGFloat(max(0, slice.count - 1))
            if width > maxWidth { return nil }
            result.append(slice)
            start += take
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let rows = Self.packRows(widths: widths, spacing: spacing,
                                 maxWidth: proposal.width ?? .infinity, balanced: balanced)
        let height = rows.map { rowHeight($0, subviews) }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map { rowWidth($0, subviews) }.max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        var y = bounds.minY
        for row in Self.packRows(widths: widths, spacing: spacing,
                                 maxWidth: bounds.width, balanced: balanced) {
            let rowH = rowHeight(row, subviews)
            var x: CGFloat
            switch alignment {
            case .leading: x = bounds.minX
            case .center: x = bounds.minX + (bounds.width - rowWidth(row, subviews)) / 2
            }
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (rowH - size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += rowH + spacing
        }
    }

    private func rowWidth(_ row: [Int], _ subviews: Subviews) -> CGFloat {
        row.map { subviews[$0].sizeThatFits(.unspecified).width }.reduce(0, +)
            + spacing * CGFloat(max(0, row.count - 1))
    }

    private func rowHeight(_ row: [Int], _ subviews: Subviews) -> CGFloat {
        row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
    }
}
