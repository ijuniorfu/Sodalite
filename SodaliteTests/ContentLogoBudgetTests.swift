import Testing
import CoreGraphics
@testable import Sodalite

struct ContentLogoBudgetTests {

    // MARK: - Tier resolution

    @Test func tvWinsOverSizeClass() {
        #expect(ContentLogoTier.tier(isTV: true, compact: true, portrait: true) == .tv)
        #expect(ContentLogoTier.tier(isTV: true, compact: false, portrait: false) == .tv)
    }

    @Test func phoneSplitsByOrientation() {
        #expect(ContentLogoTier.tier(isTV: false, compact: true, portrait: true) == .phonePortrait)
        #expect(ContentLogoTier.tier(isTV: false, compact: true, portrait: false) == .phoneLandscape)
    }

    @Test func regularIsTheTabletTier() {
        #expect(ContentLogoTier.tier(isTV: false, compact: false, portrait: true) == .regular)
        #expect(ContentLogoTier.tier(isTV: false, compact: false, portrait: false) == .regular)
    }

    // MARK: - Budget

    @Test func budgetIsAFractionOfTheMeasuredColumn() {
        let tv = ContentLogoTier.tv.budget(columnWidth: 1820)
        #expect(tv.maxHeight == 165)
        #expect(abs(tv.maxWidth - 764.4) < 0.01)

        let portrait = ContentLogoTier.phonePortrait.budget(columnWidth: 361)
        #expect(portrait.maxHeight == 88)
        #expect(abs(portrait.maxWidth - 288.8) < 0.01)
    }

    /// A column of 0 means geometry has not landed yet. The budget must stay usable, never collapse
    /// the mark to nothing.
    @Test func unmeasuredColumnFallsBackToTheTierNominal() {
        let budget = ContentLogoTier.regular.budget(columnWidth: 0)
        #expect(budget.maxWidth == ContentLogoTier.regular.nominalColumn * 0.55)
        #expect(budget.maxHeight == 130)
    }

    // MARK: - Sizing

    @Test func stackedLogoKeepsTheFullHeight() {
        let size = ContentLogoSizing.size(aspect: 1, in: .init(maxWidth: 764, maxHeight: 165))
        #expect(size == CGSize(width: 165, height: 165))
    }

    @Test func kneeIsTheLastFullHeightAspect() {
        let budget = ContentLogoBudget(maxWidth: 5000, maxHeight: 165)
        let atKnee = ContentLogoSizing.size(aspect: ContentLogoSizing.areaKnee, in: budget)
        #expect(abs(atKnee.height - 165) < 0.001)
        let past = ContentLogoSizing.size(aspect: ContentLogoSizing.areaKnee + 0.5, in: budget)
        #expect(past.height < 165)
    }

    /// The whole point of the change: above the knee every mark covers the same area, so a 6:1
    /// wordmark and a 3:1 one carry the same optical weight instead of double.
    @Test func wideLogosHoldConstantArea() {
        let budget = ContentLogoBudget(maxWidth: 100_000, maxHeight: 165)
        let expected = ContentLogoSizing.areaKnee * 165 * 165
        for aspect in [3.0, 4.5, 6.0, 8.0] as [CGFloat] {
            let size = ContentLogoSizing.size(aspect: aspect, in: budget)
            #expect(abs(size.width * size.height - expected) < 0.5)
            #expect(abs(size.width / size.height - aspect) < 0.001)
        }
    }

    @Test func bannerLogoStopsAtTheHeightFloor() {
        let budget = ContentLogoBudget(maxWidth: 100_000, maxHeight: 100)
        let size = ContentLogoSizing.size(aspect: 20, in: budget)
        #expect(abs(size.height - 45) < 0.001)
        #expect(abs(size.width - 900) < 0.001)
    }

    @Test func widthCapWinsOverTheHeightBudget() {
        let size = ContentLogoSizing.size(aspect: 12, in: .init(maxWidth: 764, maxHeight: 165))
        #expect(abs(size.width - 764) < 0.001)
        #expect(abs(size.height - 764.0 / 12.0) < 0.001)
    }

    /// Today's height-only cap against the budget, on the numbers from Sodalite#97: a 6:1 mark on
    /// tvOS drew 900pt wide, half the column.
    @Test func wideMarkNoLongerSprawlsAcrossTheColumn() {
        let column: CGFloat = 1820
        let size = ContentLogoSizing.size(aspect: 6, in: ContentLogoTier.tv.budget(columnWidth: column))
        #expect(size.width / column < 0.35)
        let stacked = ContentLogoSizing.size(aspect: 1, in: ContentLogoTier.tv.budget(columnWidth: column))
        #expect(size.width * size.height / (stacked.width * stacked.height) < 2.5)
    }

    // MARK: - Degenerate input

    @Test func aspectIsClampedRatherThanTrusted() {
        let budget = ContentLogoBudget(maxWidth: 764, maxHeight: 165)
        #expect(ContentLogoSizing.size(aspect: 0, in: budget).height == 165)
        #expect(ContentLogoSizing.size(aspect: -3, in: budget).height == 165)
        #expect(ContentLogoSizing.size(aspect: .nan, in: budget) == CGSize(width: 165, height: 165))
        #expect(ContentLogoSizing.size(aspect: .infinity, in: budget).width <= 764)
    }

    @Test func emptyBudgetIsEmpty() {
        #expect(ContentLogoSizing.size(aspect: 3, in: .init(maxWidth: 0, maxHeight: 165)) == .zero)
        #expect(ContentLogoSizing.size(aspect: 3, in: .init(maxWidth: 764, maxHeight: 0)) == .zero)
    }

    // MARK: - Pixel request

    /// The requested box must be a tier constant. Deriving it from the measured column or the
    /// decoded aspect would change the URL after the image lands, re-firing AsyncCachedImage's
    /// task(id:) and flashing the very swap this change removes.
    @Test func requestBoxIsIndependentOfColumnAndAspect() {
        let a = ContentLogoTier.tv.requestPixels(scale: 2)
        let b = ContentLogoTier.tv.requestPixels(scale: 2)
        #expect(a == b)
        #expect(a.width == Int((ContentLogoTier.tv.nominalColumn * 0.42 * 2).rounded()))
        #expect(a.height == 330)
    }

    @Test func requestBoxFollowsTheScale() {
        let oneX = ContentLogoTier.phonePortrait.requestPixels(scale: 1)
        let threeX = ContentLogoTier.phonePortrait.requestPixels(scale: 3)
        #expect(oneX.height == 88)
        #expect(threeX.height == 264)
        #expect(abs(threeX.width - 3 * oneX.width) <= 2)
    }
}
