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

    /// The collapsed row is square around its icon: the same padding on all four sides, so the
    /// focus pill reads as a tile rather than a stretched capsule, and the rail costs the content
    /// no more width than the icon actually needs.
    static func itemHorizontalPadding(isExpanded: Bool) -> CGFloat {
        isExpanded ? horizontalPadding : itemVerticalPadding
    }

    /// Measured from the physical edge, not from the safe area: the rail deliberately reaches into
    /// tvOS's 60pt title-safe margin, which is what Apple's own sidebar does (its panel sits about
    /// 38pt from the edge). Staying outside it stacks 60 + inset and reads as a wide empty gutter.
    static let railLeadingInset: CGFloat = 40

    /// The leading edge of every screen while the sidebar is up, and deliberately the SAME number
    /// as `railLeadingInset`: the gap from the screen edge to the rail then equals the gap from the
    /// rail to the content, which is the symmetry the eye actually checks.
    ///
    /// It also has to swallow the focus lift, and that is why 16pt was not enough: a settings tile
    /// is screen-wide and `FocusResponse.tile` scales it 1.03, so it grows about 25pt per side,
    /// plus its shadow. A media card grows 8. The bigger of the two sets the number.
    static var contentLeading: CGFloat { railLeadingInset }
    /// Gap between the icon column and the label.
    static let labelSpacing: CGFloat = 16

    static var collapsedWidth: CGFloat { iconColumn + itemHorizontalPadding(isExpanded: false) * 2 }

    /// Everything the rail occupies on the leading edge: its own inset plus its collapsed width.
    static var railSlot: CGFloat { railLeadingInset + collapsedWidth }

    /// What is left for the label once the icon column and the paddings have taken their share.
    static var labelWidthBudget: CGFloat {
        expandedWidth - iconColumn - labelSpacing - horizontalPadding * 2
    }
    /// A cap, not a promise: labels are `lineLimit(1)`, and 26 locales include longer compounds.
    /// 360 rather than 300 because German ("Einstellungen") overran the narrower rail on device.
    static let expandedWidth: CGFloat = 360

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
