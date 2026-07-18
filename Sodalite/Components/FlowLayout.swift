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

    static func packRows(widths: [CGFloat], spacing: CGFloat, maxWidth: CGFloat) -> [[Int]] {
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
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let rows = Self.packRows(widths: widths, spacing: spacing, maxWidth: proposal.width ?? .infinity)
        let height = rows.map { rowHeight($0, subviews) }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map { rowWidth($0, subviews) }.max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        var y = bounds.minY
        for row in Self.packRows(widths: widths, spacing: spacing, maxWidth: bounds.width) {
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
