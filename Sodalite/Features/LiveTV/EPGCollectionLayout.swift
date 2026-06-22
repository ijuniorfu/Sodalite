import UIKit

/// Per-program time geometry, implemented by the view controller from `EPGGuideViewModel`.
protocol EPGCollectionLayoutDelegate: AnyObject {
    func epgChannelCount() -> Int
    func epgProgramCount(section: Int) -> Int
    /// Content-space x and width (points) in the program area's own space (x 0 = axis start).
    func epgProgramXWidth(section: Int, item: Int) -> (x: CGFloat, width: CGFloat)
}

/// Program grid only: cells by time (x) and channel (row) plus a "now" line. Channel column and
/// time header are SEPARATE sibling views (hard split, so programs never scroll under the column);
/// no pinned supplementaries, so this does not relayout on scroll.
final class EPGCollectionLayout: UICollectionViewLayout {

    static let nowLineKind = "EPGNowLine"
    static let gridLineKind = "EPGGridLine"

    weak var delegate: EPGCollectionLayoutDelegate?

    var rowHeight: CGFloat = 110
    /// Total width of the program timeline (axis span * points-per-minute).
    var totalWidth: CGFloat = 0
    var nowX: CGFloat = 0
    /// Content-space x of each half-hour gridline, matching the time header's labels.
    var gridlineXs: [CGFloat] = []

    private var cellAttributesBySection: [[UICollectionViewLayoutAttributes]] = []
    private var gridlineAttributes: [UICollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let delegate else { cellAttributesBySection = []; gridlineAttributes = []; return }
        let sections = delegate.epgChannelCount()
        contentHeight = CGFloat(sections) * rowHeight
        cellAttributesBySection = (0..<sections).map { s in
            let count = delegate.epgProgramCount(section: s)
            let y = CGFloat(s) * rowHeight
            return (0..<count).map { i in
                let (x, w) = delegate.epgProgramXWidth(section: s, item: i)
                let attr = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: s))
                attr.frame = CGRect(x: x, y: y, width: max(w, 1), height: rowHeight)
                return attr
            }
        }
        // Gridlines span full content height at zIndex -1 so programs and the now line draw on top.
        gridlineAttributes = gridlineXs.enumerated().map { idx, x in
            let attr = UICollectionViewLayoutAttributes(
                forDecorationViewOfKind: Self.gridLineKind, with: IndexPath(item: idx, section: 0))
            attr.frame = CGRect(x: x, y: 0, width: 1, height: contentHeight)
            attr.zIndex = -1
            return attr
        }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: max(totalWidth, 1), height: contentHeight)
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section < cellAttributesBySection.count,
              indexPath.item < cellAttributesBySection[indexPath.section].count else { return nil }
        return cellAttributesBySection[indexPath.section][indexPath.item]
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let sectionCount = cellAttributesBySection.count
        guard sectionCount > 0, rowHeight > 0 else { return [] }
        var result: [UICollectionViewLayoutAttributes] = []
        for attr in gridlineAttributes where attr.frame.intersects(rect) {
            result.append(attr)
        }
        let firstRow = max(0, Int(rect.minY / rowHeight))
        let lastRow = min(sectionCount - 1, Int(rect.maxY / rowHeight))
        if firstRow <= lastRow {
            for s in firstRow...lastRow {
                for attr in cellAttributesBySection[s] where attr.frame.intersects(rect) {
                    result.append(attr)
                }
            }
        }
        if let now = nowLineAttributes(), now.frame.intersects(rect) { result.append(now) }
        return result
    }

    override func layoutAttributesForDecorationView(
        ofKind elementKind: String, at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        switch elementKind {
        case Self.nowLineKind:
            return nowLineAttributes()
        case Self.gridLineKind:
            return indexPath.item < gridlineAttributes.count ? gridlineAttributes[indexPath.item] : nil
        default:
            return nil
        }
    }

    private func nowLineAttributes() -> UICollectionViewLayoutAttributes? {
        guard contentHeight > 0, nowX >= 0, nowX <= totalWidth else { return nil }
        let attr = UICollectionViewLayoutAttributes(
            forDecorationViewOfKind: Self.nowLineKind, with: IndexPath(item: 0, section: 0))
        attr.frame = CGRect(x: nowX - 1, y: 0, width: 2, height: contentHeight)
        attr.zIndex = 3
        return attr
    }
}
