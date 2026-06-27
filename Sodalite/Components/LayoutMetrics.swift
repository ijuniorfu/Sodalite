import SwiftUI

/// Platform + size-class layout knobs for the browse UI. tvOS (10-foot) keeps its
/// large values; iPad regular gets a middle tier; iPhone compact gets phone scale.
/// Card sizes are pre-cardScale; callers still multiply by appearancePreferences.cardScale.
struct LayoutMetrics: Equatable {
    var posterSize: CGSize
    var landscapeSize: CGSize
    var squareSize: CGSize
    var rowInset: CGFloat
    var itemSpacing: CGFloat
    var rowVerticalPadding: CGFloat
    var gridMinimum: CGFloat
    var gridSpacing: CGFloat

    func size(for style: MediaCardStyle) -> CGSize {
        switch style {
        case .poster: posterSize
        case .landscape: landscapeSize
        case .square: squareSize
        }
    }

    /// tvOS 10-foot tier: the current shipped values (keeps tvOS byte-identical).
    static let tv = LayoutMetrics(
        posterSize: CGSize(width: 220, height: 330),
        landscapeSize: CGSize(width: 360, height: 202),
        squareSize: CGSize(width: 220, height: 220),
        rowInset: 50, itemSpacing: 30, rowVerticalPadding: 20,
        gridMinimum: 220, gridSpacing: 40
    )
    /// iPad regular tier.
    static let regular = LayoutMetrics(
        posterSize: CGSize(width: 160, height: 240),
        landscapeSize: CGSize(width: 280, height: 158),
        squareSize: CGSize(width: 160, height: 160),
        rowInset: 28, itemSpacing: 20, rowVerticalPadding: 16,
        gridMinimum: 160, gridSpacing: 28
    )
    /// iPhone compact tier.
    static let compact = LayoutMetrics(
        posterSize: CGSize(width: 120, height: 180),
        landscapeSize: CGSize(width: 200, height: 112),
        squareSize: CGSize(width: 120, height: 120),
        rowInset: 16, itemSpacing: 12, rowVerticalPadding: 12,
        gridMinimum: 108, gridSpacing: 16
    )

    /// Platform-independent selector (testable on any target).
    static func metrics(compact: Bool, isTV: Bool) -> LayoutMetrics {
        if isTV { return .tv }
        return compact ? .compact : .regular
    }

    /// Resolves the tier for the current platform + size class.
    static func current(_ sizeClass: UserInterfaceSizeClass?) -> LayoutMetrics {
        #if os(tvOS)
        return metrics(compact: false, isTV: true)
        #else
        return metrics(compact: sizeClass == .compact, isTV: false)
        #endif
    }
}
