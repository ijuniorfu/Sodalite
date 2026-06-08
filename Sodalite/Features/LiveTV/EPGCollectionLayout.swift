import UIKit

/// Supplies the layout with the per-program time geometry. The view
/// controller implements it from `EPGGuideViewModel`.
protocol EPGCollectionLayoutDelegate: AnyObject {
    func epgChannelCount() -> Int
    func epgProgramCount(section: Int) -> Int
    /// Content-space x (relative to the program area origin, i.e. excluding
    /// the channel column) and width, in points, for a program block.
    func epgProgramXWidth(section: Int, item: Int) -> (x: CGFloat, width: CGFloat)
}

/// Custom collection-view layout for the EPG: a 2D scrollable program grid
/// with a channel column pinned on the left and a time header pinned on top.
///
/// The channel column, time header and corner are supplementary / decoration
/// views whose frames are re-derived from `collectionView.contentOffset` on
/// every bounds change, so they stay welded to the grid as the user scrolls
/// (including tvOS focus-driven auto-scroll). This pinning happens in the
/// UIKit layout pass, not as a SwiftUI state update, and program cells are
/// recycled, so it stays smooth over hundreds of channels.
///
/// Coordinate model: the collection view carries a `contentInset` of
/// `(top: headerHeight, left: columnWidth)`. Program cells live at content
/// origin (0, 0); the inset reserves the header/column strips and makes the
/// focus engine keep focused cells out from under them. A view at content-x
/// `X` appears on screen at `X - contentOffset.x`; at rest `contentOffset` is
/// `(-columnWidth, -headerHeight)`, so content-x 0 sits at screen-x
/// `columnWidth` (right of the column) and a pinned view at content-x
/// `contentOffset.x` sits at screen-x 0 (the left edge).
final class EPGCollectionLayout: UICollectionViewLayout {

    static let channelHeaderKind = "EPGChannelHeader"
    static let timeHeaderKind = "EPGTimeHeader"
    static let cornerKind = "EPGCorner"
    static let nowLineKind = "EPGNowLine"

    weak var delegate: EPGCollectionLayoutDelegate?

    // Geometry, set by the view controller from the model.
    var columnWidth: CGFloat = 260
    var headerHeight: CGFloat = 60
    var rowHeight: CGFloat = 110
    /// Total width of the program timeline (axis span * points-per-minute).
    var totalWidth: CGFloat = 0
    /// Content-space x of the "now" line within the program area.
    var nowX: CGFloat = 0

    /// Program cell attributes grouped by section (row), so a rect query only
    /// has to touch the visible rows rather than every cell in the grid.
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
                attr.zIndex = 0
                return attr
            }
        }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: max(totalWidth, 1), height: contentHeight)
    }

    // Pinned views depend on the live content offset, so re-layout on scroll.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section < cellAttributesBySection.count,
              indexPath.item < cellAttributesBySection[indexPath.section].count else { return nil }
        return cellAttributesBySection[indexPath.section][indexPath.item]
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let sectionCount = cellAttributesBySection.count
        guard sectionCount > 0, rowHeight > 0 else {
            // No rows, but the pinned time header / corner may still show.
            var pinned: [UICollectionViewLayoutAttributes] = []
            if let timeHeader = timeHeaderAttributes() { pinned.append(timeHeader) }
            if let corner = cornerAttributes() { pinned.append(corner) }
            return pinned
        }

        // Only touch the rows the query rect overlaps.
        let firstRow = max(0, Int(rect.minY / rowHeight))
        let lastRow = min(sectionCount - 1, Int(rect.maxY / rowHeight))
        var result: [UICollectionViewLayoutAttributes] = []
        if firstRow <= lastRow {
            for s in firstRow...lastRow {
                for attr in cellAttributesBySection[s] where attr.frame.intersects(rect) {
                    result.append(attr)
                }
                if let header = channelHeaderAttributes(section: s) { result.append(header) }
            }
        }
        if let timeHeader = timeHeaderAttributes() { result.append(timeHeader) }
        if let corner = cornerAttributes() { result.append(corner) }
        if let now = nowLineAttributes() { result.append(now) }
        return result
    }

    // MARK: - Supplementary / decoration

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: String, at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        switch elementKind {
        case Self.channelHeaderKind: return channelHeaderAttributes(section: indexPath.section)
        case Self.timeHeaderKind: return timeHeaderAttributes()
        case Self.cornerKind: return cornerAttributes()
        default: return nil
        }
    }

    override func layoutAttributesForDecorationView(
        ofKind elementKind: String, at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        elementKind == Self.nowLineKind ? nowLineAttributes() : nil
    }

    private func channelHeaderAttributes(section: Int) -> UICollectionViewLayoutAttributes? {
        guard let cv = collectionView else { return nil }
        let attr = UICollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: Self.channelHeaderKind,
            with: IndexPath(item: 0, section: section))
        // Pinned to the left edge (screen-x 0): content-x == contentOffset.x.
        attr.frame = CGRect(
            x: cv.contentOffset.x, y: CGFloat(section) * rowHeight,
            width: columnWidth, height: rowHeight)
        attr.zIndex = 5
        return attr
    }

    private func timeHeaderAttributes() -> UICollectionViewLayoutAttributes? {
        guard let cv = collectionView else { return nil }
        let attr = UICollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: Self.timeHeaderKind,
            with: IndexPath(item: 0, section: 0))
        // Pinned to the top (screen-y 0): content-y == contentOffset.y. Spans
        // the timeline and scrolls horizontally with the programs.
        attr.frame = CGRect(x: 0, y: cv.contentOffset.y, width: totalWidth, height: headerHeight)
        attr.zIndex = 6
        return attr
    }

    private func cornerAttributes() -> UICollectionViewLayoutAttributes? {
        guard let cv = collectionView else { return nil }
        let attr = UICollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: Self.cornerKind,
            with: IndexPath(item: 0, section: 0))
        attr.frame = CGRect(
            x: cv.contentOffset.x, y: cv.contentOffset.y,
            width: columnWidth, height: headerHeight)
        attr.zIndex = 10
        return attr
    }

    private func nowLineAttributes() -> UICollectionViewLayoutAttributes? {
        guard contentHeight > 0, nowX >= 0, nowX <= totalWidth else { return nil }
        let attr = UICollectionViewLayoutAttributes(
            forDecorationViewOfKind: Self.nowLineKind,
            with: IndexPath(item: 0, section: 0))
        attr.frame = CGRect(x: nowX - 1, y: 0, width: 2, height: contentHeight)
        attr.zIndex = 3
        return attr
    }
}
