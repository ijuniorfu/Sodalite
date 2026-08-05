#if DEBUG
import UIKit

/// Writes the guide's actual on-device geometry to `Library/Caches/guide-geometry.txt`.
///
/// It exists because the bottom row rendered SHORTER than the layout's row height instead of being
/// clipped by the viewport, three fix attempts in a row missed, and a photo of a television can
/// measure that a row is wrong but not why. `LogTap` is not an option here: the only UI that renders
/// it is the in-player overlay, and this is a guide-screen defect.
///
/// Caches, not Documents: tvOS forbids app writes to Documents and the failure is silent.
enum GuideGeometryProbe {
    private static var writes = 0
    private static var lastWrite = Date.distantPast
    /// Enough samples to cover a few scroll positions, few enough that the file stays readable.
    private static let maxWrites = 30
    private static let throttle: TimeInterval = 1.5

    static func record(_ label: String, controller: UIViewController,
                       grid: UICollectionView, column: UICollectionView) {
        guard writes < maxWrites, Date().timeIntervalSince(lastWrite) > throttle else { return }
        lastWrite = Date()
        writes += 1

        var lines = ["=== \(label) #\(writes) \(Self.stamp.string(from: Date()))"]
        let window = controller.view.window
        lines.append("screen=\(fmt(window?.screen.bounds ?? .zero)) "
            + "windowSafe=\(fmt(window?.safeAreaInsets ?? .zero))")
        lines.append("ctrlView bounds=\(fmt(controller.view.bounds)) "
            + "safe=\(fmt(controller.view.safeAreaInsets)) "
            + "addl=\(fmt(controller.additionalSafeAreaInsets))")
        lines.append(describe("grid", grid))
        lines.append(contentsOf: cellLines(grid, kind: "grid"))
        lines.append(describe("column", column))
        lines.append(contentsOf: cellLines(column, kind: "column"))
        append(lines.joined(separator: "\n") + "\n")
    }

    /// Focus trace. Separate budget from the geometry samples: the question is where the chain from
    /// "player closed" to "grid focused" breaks, and one round trip must fit in the file.
    private static var focusLines = 0

    static func logFocus(_ message: String) {
        guard focusLines < 120 else { return }
        focusLines += 1
        append("[focus \(Self.stamp.string(from: Date()))] \(message)\n")
    }

    /// The focused row, program by program, with the geometry each one was given. The bubble at the
    /// left edge has an outer rounded corner of its own, so it is a genuinely narrow cell rather than
    /// a clipped one, and only the row's own numbers say where such a cell comes from.
    static func logRow(section: Int, item: Int, offset: CGFloat, viewport: CGFloat,
                       entries: [(name: String, times: String, x: CGFloat, width: CGFloat)]) {
        guard focusLines < 120 else { return }
        focusLines += 1
        var text = String(format: "[row %@] section=%d item=%d offset=%.0f viewport=%.0f\n",
                          Self.stamp.string(from: Date()), section, item, offset, viewport)
        for (index, entry) in entries.enumerated() {
            text += String(format: "    %d%@ x=%.0f w=%.0f  %@  %@\n",
                           index, index == item ? "*" : " ", entry.x, entry.width,
                           entry.times, entry.name)
        }
        append(text)
    }

    /// What the focus engine currently has, so a denied request can be told from one that never ran.
    static func focusedDescription(near view: UIView) -> String {
        guard let item = UIFocusSystem.focusSystem(for: view)?.focusedItem else { return "none" }
        return String(describing: type(of: item))
    }

    private static func describe(_ name: String, _ view: UICollectionView) -> String {
        "\(name) frame=\(fmt(view.frame)) bounds=\(fmt(view.bounds)) "
            + "content=\(fmt(view.contentSize)) offset=\(fmt(view.contentOffset)) "
            + "inset=\(fmt(view.contentInset)) adjusted=\(fmt(view.adjustedContentInset)) "
            + "safe=\(fmt(view.safeAreaInsets))"
    }

    /// The three lowest visible cells: the defect is at the bottom edge, everything above it is fine.
    private static func cellLines(_ view: UICollectionView, kind: String) -> [String] {
        let cells = view.visibleCells.sorted { $0.frame.minY < $1.frame.minY }.suffix(3)
        return cells.map { cell in
            let path = view.indexPath(for: cell)
            let attrs = path.flatMap { view.collectionViewLayout.layoutAttributesForItem(at: $0) }
            // The hosting view is what UIHostingConfiguration installs; if the SwiftUI content is
            // being squeezed rather than clipped, its frame is where that shows up.
            let host = cell.contentView.subviews.first
            return "  \(kind) \(path.map { "[\($0.section),\($0.item)]" } ?? "?") "
                + "attrs=\(fmt(attrs?.frame ?? .zero)) cell=\(fmt(cell.frame)) "
                + "content=\(fmt(cell.contentView.frame)) "
                + "host=\(host.map { fmt($0.frame) } ?? "-") "
                + "cellSafe=\(fmt(cell.safeAreaInsets)) "
                + "hostSafe=\(host.map { fmt($0.safeAreaInsets) } ?? "-") "
                + "alpha=\(String(format: "%.2f", cell.alpha)) clip=\(cell.clipsToBounds)"
        }
    }

    private static func fmt(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.width, r.height)
    }
    private static func fmt(_ p: CGPoint) -> String { String(format: "(%.0f,%.0f)", p.x, p.y) }
    private static func fmt(_ s: CGSize) -> String { String(format: "(%.0fx%.0f)", s.width, s.height) }
    private static func fmt(_ i: UIEdgeInsets) -> String {
        String(format: "(t%.0f l%.0f b%.0f r%.0f)", i.top, i.left, i.bottom, i.right)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static var url: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("guide-geometry.txt")
    }

    private static func append(_ text: String) {
        guard let url, let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { _ = try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
