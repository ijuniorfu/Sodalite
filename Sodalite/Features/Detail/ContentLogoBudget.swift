import CoreGraphics

/// Two-axis room the detail-page title logo may occupy: a fraction of the column it sits in, and
/// the tier's height cap. Both bounds are needed. A height cap alone lets the source asset's aspect
/// ratio decide how much of the page the mark covers (Sodalite#97).
struct ContentLogoBudget: Equatable {
    var maxWidth: CGFloat
    var maxHeight: CGFloat
}

/// Where the logo is being drawn. Not `LayoutMetrics`: the phone wants a different budget in
/// portrait than in landscape, and that split has no meaning for any other metric in that table.
enum ContentLogoTier: Equatable {
    case tv
    case regular
    case phoneLandscape
    case phonePortrait

    static func tier(isTV: Bool, compact: Bool, portrait: Bool) -> ContentLogoTier {
        if isTV { return .tv }
        guard compact else { return .regular }
        return portrait ? .phonePortrait : .phoneLandscape
    }

    /// Height cap, per tier. One shared value was the defect: 150pt is 8% of a tvOS column and 15%
    /// of an iPad one, so no single number can be right on both.
    var maxHeight: CGFloat {
        switch self {
        case .tv: 165
        case .regular: 130
        case .phoneLandscape: 84
        case .phonePortrait: 88
        }
    }

    /// Share of the column the mark may span. The secondary guard: once the height is normalized by
    /// aspect this binds only for banner-shaped marks and narrow columns (iPad split view, phone
    /// portrait).
    var columnFraction: CGFloat {
        switch self {
        case .tv: 0.42
        case .regular: 0.55
        case .phoneLandscape: 0.60
        case .phonePortrait: 0.80
        }
    }

    /// Widest column the tier can present, used for two things that must not depend on a live
    /// measurement: the pixel size requested from the server, and the budget on a frame where
    /// geometry has not landed yet (layout runs before AsyncCachedImage's task, so in practice the
    /// measured width is always there before an image can be drawn).
    var nominalColumn: CGFloat {
        switch self {
        case .tv: 1820          // 1920 minus 2x LayoutMetrics.tv.rowInset
        case .regular: 1310     // 12.9" iPad, landscape, full width
        case .phoneLandscape: 900
        case .phonePortrait: 408
        }
    }

    func budget(columnWidth: CGFloat) -> ContentLogoBudget {
        let column = columnWidth > 0 ? columnWidth : nominalColumn
        return ContentLogoBudget(maxWidth: column * columnFraction, maxHeight: maxHeight)
    }

    /// Box to ask Jellyfin for, in points, per DEVICE FAMILY rather than per tier: the two phone
    /// tiers share one box, so rotating the phone cannot change the URL. It can, and then every
    /// rotation drops `loaded`, refetches and flashes. The box covers the widest and tallest budget
    /// in its family.
    ///
    /// Constant ON PURPOSE, for the same reason: sizing the request off the measured column or the
    /// decoded aspect would move the URL after the image lands, re-firing AsyncCachedImage's
    /// `task(id:)`.
    var requestPoints: CGSize {
        switch self {
        case .tv: CGSize(width: 1820 * 0.42, height: 165)
        case .regular: CGSize(width: 1310 * 0.55, height: 130)
        case .phoneLandscape, .phonePortrait: CGSize(width: 900 * 0.60, height: 88)
        }
    }

    /// Pixel box for the request. Jellyfin fits the image inside it and keeps its aspect, so
    /// bounding both axes covers a wide mark without pulling a needlessly tall payload for a
    /// stacked one.
    func requestPixels(scale: CGFloat) -> (width: Int, height: Int) {
        let box = requestPoints
        return (
            width: Int((box.width * scale).rounded()),
            height: Int((box.height * scale).rounded())
        )
    }
}

/// Sizes a logo inside its budget, normalized for optical weight.
///
/// Height alone (what shipped before Sodalite#97) makes rendered area a direct function of the
/// source asset's aspect ratio: a 6:1 wordmark covers six times the ink of a 1:1 stacked mark at
/// the same cap. Above `areaKnee` the height is pulled back so area stays constant instead, which
/// leaves the two within about 2x of each other.
enum ContentLogoSizing {
    /// Marks up to this aspect are sized by height, as before. Past it, by area.
    static let areaKnee: CGFloat = 2.2
    /// Height floor, as a fraction of the budget, so a very long banner does not thin away to a line.
    static let heightFloor: CGFloat = 0.45

    static func size(aspect: CGFloat, in budget: ContentLogoBudget) -> CGSize {
        guard budget.maxWidth > 0, budget.maxHeight > 0 else { return .zero }
        // A decode that reported nothing usable is drawn square rather than propagating a NaN into
        // a frame modifier.
        let sane = aspect.isFinite && aspect > 0 ? aspect : 1
        let a = min(max(sane, 0.2), 20)

        let normalized = a <= areaKnee ? budget.maxHeight : budget.maxHeight * (areaKnee / a).squareRoot()
        let height = max(normalized, budget.maxHeight * heightFloor)
        let width = height * a
        guard width > budget.maxWidth else {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: budget.maxWidth, height: budget.maxWidth / a)
    }
}
