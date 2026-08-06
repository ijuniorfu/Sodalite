import SwiftUI

/// Guide geometry per platform tier. Two tiers, not three: the compact size class gets
/// `ChannelListView` instead of a grid, so there is no phone-scale grid to describe.
struct GuideMetrics: Equatable {
    var heroHeight: CGFloat
    var heroThumbSize: CGSize
    var controlsHeight: CGFloat
    var rulerHeight: CGFloat
    var rowHeight: CGFloat
    var channelColumnWidth: CGFloat
    var pointsPerMinute: CGFloat
    var channelLogoSize: CGFloat
    var favoriteIconSize: CGFloat

    static let tv = GuideMetrics(
        heroHeight: 170, heroThumbSize: CGSize(width: 200, height: 112),
        controlsHeight: 56, rulerHeight: 44, rowHeight: 100,
        channelColumnWidth: 320, pointsPerMinute: 8,
        channelLogoSize: 52, favoriteIconSize: 24)

    static let regular = GuideMetrics(
        heroHeight: 132, heroThumbSize: CGSize(width: 148, height: 83),
        controlsHeight: 48, rulerHeight: 36, rowHeight: 80,
        channelColumnWidth: 200, pointsPerMinute: 6,
        channelLogoSize: 40, favoriteIconSize: 20)

    static var current: GuideMetrics {
        #if os(tvOS)
        .tv
        #else
        .regular
        #endif
    }

    /// One ruler chip, one gridline gap. Derived from `GuideAxis.slotMinutes` so the two cannot drift.
    var slotWidth: CGFloat { CGFloat(GuideAxis.slotMinutes) * pointsPerMinute }
}
