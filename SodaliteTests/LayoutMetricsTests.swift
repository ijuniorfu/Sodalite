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
}
