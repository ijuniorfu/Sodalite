import CoreGraphics

/// Sodalite#140. Geometry of the tvOS sidebar. The pitch is the one measured number (76pt, read off
/// the system sidebar in the simulator); everything that could contradict it is derived, so a
/// retune of the icon or the padding moves the gap rather than the rhythm.
enum SidebarMetrics {
    static let rowPitch: CGFloat = 76
    static let iconSize: CGFloat = 30
    /// Fixed column so icons line up whether or not their glyphs are the same width.
    static let iconColumn: CGFloat = 36
    static let itemVerticalPadding: CGFloat = 14
    static let horizontalPadding: CGFloat = 20
    static let cornerRadius: CGFloat = 16
    static let panelCornerRadius: CGFloat = 28

    static let collapsedWidth: CGFloat = 90
    /// A cap, not a promise: labels are `lineLimit(1)`, and 26 locales include longer compounds.
    static let expandedWidth: CGFloat = 300

    /// Matches the scrim in `menuPresentation`, the app's other "a panel arrives" curve.
    static let expandDuration: Double = 0.35

    static var itemHeight: CGFloat { iconSize + itemVerticalPadding * 2 }
    static var itemSpacing: CGFloat { rowPitch - itemHeight }

    /// Height of the divider that sets Settings apart, including the space around it.
    static let dividerHeight: CGFloat = 1
    static var dividerBand: CGFloat { dividerHeight + itemSpacing }

    static func width(isExpanded: Bool) -> CGFloat {
        isExpanded ? expandedWidth : collapsedWidth
    }

    /// What the centred block occupies, so a caller can check it against the title-safe band.
    static func blockHeight(itemCount: Int, hasProfileHeader: Bool) -> CGFloat {
        let rows = CGFloat(itemCount) + (hasProfileHeader ? 1 : 0)
        guard rows > 0 else { return 0 }
        return rows * itemHeight + (rows - 1) * itemSpacing + dividerBand
    }
}
