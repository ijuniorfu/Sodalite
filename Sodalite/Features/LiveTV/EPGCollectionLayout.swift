import UIKit

/// Supplies the program layout with the per-program time geometry. The view
/// controller implements it from `EPGGuideViewModel`.
protocol EPGCollectionLayoutDelegate: AnyObject {
    func epgChannelCount() -> Int
    func epgProgramCount(section: Int) -> Int
    /// Content-space x and width, in points, for a program block (the program
    /// area's own coordinate space, where x 0 is the axis start).
    func epgProgramXWidth(section: Int, item: Int) -> (x: CGFloat, width: CGFloat)
}

/// Layout for the program grid only: program cells positioned by time (x) and
/// channel (row), plus a "now" line decoration. The channel column and time
/// header are SEPARATE sibling views in the view controller (a hard split, so
/// programs never scroll under the column); this layout has no pinned
/// supplementary views and therefore does not relayout on scroll.
final class EPGCollectionLayout: UICollectionViewLayout {

    static let nowLineKind = "EPGNowLine"

    weak var delegate: EPGCollectionLayoutDelegate?

    var rowHeight: CGFloat = 110
    /// Total width of the program timeline (axis span * points-per-minute).
    var totalWidth: CGFloat = 0
    /// Content-space x of the "now" line.
    var nowX: CGFloat = 0

    private var cellAttributesBySection: [[UICollectionViewLayoutAttributes]] = []
    private var contentHeight: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let delegate else { cellAttributesBySection = []; return }
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
        let firstRow = max(0, Int(rect.minY / rowHeight))
        let lastRow = min(sectionCount - 1, Int(rect.maxY / rowHeight))
        var result: [UICollectionViewLayoutAttributes] = []
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
        elementKind == Self.nowLineKind ? nowLineAttributes() : nil
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
