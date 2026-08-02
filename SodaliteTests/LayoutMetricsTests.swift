import Testing
import SwiftUI
@testable import Sodalite

struct LayoutMetricsTests {
    @Test func compactTierIsPhoneScale() {
        let m = LayoutMetrics.metrics(compact: true, isTV: false)
        #expect(m == .compact)
        #expect(m.posterSize == CGSize(width: 120, height: 180))
        #expect(m.rowInset == 16)
    }

    @Test func regularTierIsIpadScale() {
        let m = LayoutMetrics.metrics(compact: false, isTV: false)
        #expect(m == .regular)
        #expect(m.posterSize == CGSize(width: 160, height: 240))
    }

    @Test func tvWinsOverSizeClass() {
        #expect(LayoutMetrics.metrics(compact: true, isTV: true) == .tv)
        #expect(LayoutMetrics.tv.posterSize == CGSize(width: 220, height: 330))
    }

    @Test func sizeForStyleMapsCorrectly() {
        #expect(LayoutMetrics.tv.size(for: .poster) == CGSize(width: 220, height: 330))
        #expect(LayoutMetrics.tv.size(for: .landscape) == CGSize(width: 360, height: 202))
        #expect(LayoutMetrics.compact.size(for: .square) == CGSize(width: 120, height: 120))
    }

    @Test func screenInsetTiers() {
        #expect(LayoutMetrics.tv.screenHInset == 80)
        #expect(LayoutMetrics.tv.screenVInset == 60)
        #expect(LayoutMetrics.regular.screenHInset == 40)
        #expect(LayoutMetrics.regular.screenVInset == 32)
        #expect(LayoutMetrics.compact.screenHInset == 16)
        #expect(LayoutMetrics.compact.screenVInset == 16)
    }

    @Test func profileCardTiers() {
        #expect(LayoutMetrics.tv.profileCardSize == CGSize(width: 180, height: 180))
        #expect(LayoutMetrics.regular.profileCardSize == CGSize(width: 160, height: 160))
        #expect(LayoutMetrics.compact.profileCardSize == CGSize(width: 120, height: 120))
    }

    @Test func castPortraitTiers() {
        #expect(LayoutMetrics.tv.castPortrait == 180)
        #expect(LayoutMetrics.regular.castPortrait == 120)
        #expect(LayoutMetrics.compact.castPortrait == 100)
    }

    /// The label is the part that actually broke on tvOS (Sodalite#55): caption1 is 25pt there
    /// against 12pt on a phone, so the column has to be wider than the portrait, not equal to it.
    @Test func castLabelIsWiderThanPortraitOnTenFootTiers() {
        #expect(LayoutMetrics.tv.castLabelWidth == 220)
        #expect(LayoutMetrics.tv.castLabelWidth > LayoutMetrics.tv.castPortrait)
        #expect(LayoutMetrics.regular.castLabelWidth > LayoutMetrics.regular.castPortrait)
        #expect(LayoutMetrics.compact.castLabelWidth == LayoutMetrics.compact.castPortrait)
    }

    /// A bigger circle against an unchanged image request is just a blurrier circle.
    @Test func castImageWidthCoversTheRenderedCircle() {
        #expect(LayoutMetrics.tv.castImageWidth >= Int(LayoutMetrics.tv.castPortrait * 2))
        #expect(LayoutMetrics.regular.castImageWidth >= Int(LayoutMetrics.regular.castPortrait * 2))
        #expect(LayoutMetrics.compact.castImageWidth >= Int(LayoutMetrics.compact.castPortrait * 3))
    }
}
