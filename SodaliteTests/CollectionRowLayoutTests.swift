import Foundation
import SwiftUI
import Testing
@testable import Sodalite

@Suite("Collection row layout")
struct CollectionRowLayoutTests {
    @Test("ten-foot thumb lands in the 50-75% band of the library poster")
    func tvThumbSitsInRequestedBand() {
        let tv = LayoutMetrics.tv
        let ratio = tv.listPosterSize.height / tv.posterSize.height
        #expect(ratio >= 0.5)
        #expect(ratio <= 0.75)
        #expect(tv.listPosterSize == CGSize(width: 140, height: 210))
    }

    @Test("touch tiers keep the shipped thumb size")
    func touchTiersUnchanged() {
        #expect(LayoutMetrics.regular.listPosterSize == CGSize(width: 80, height: 120))
        #expect(LayoutMetrics.compact.listPosterSize == CGSize(width: 80, height: 120))
    }

    @Test("every tier keeps the 2:3 poster aspect")
    func thumbKeepsPosterAspect() {
        for metrics in [LayoutMetrics.tv, .regular, .compact] {
            let aspect = metrics.listPosterSize.width / metrics.listPosterSize.height
            #expect(abs(aspect - 2.0 / 3.0) < 0.001)
        }
    }

    @Test("ten-foot tier lifts the row typography, touch tiers do not")
    func typographyTiers() {
        #expect(LayoutMetrics.tv.listTitleFont == Font.title3)
        #expect(LayoutMetrics.tv.listOverviewFont == Font.footnote)
        #expect(LayoutMetrics.regular.listTitleFont == Font.body)
        #expect(LayoutMetrics.regular.listOverviewFont == Font.caption)
        #expect(LayoutMetrics.compact.listTitleFont == Font.body)
        #expect(LayoutMetrics.compact.listOverviewFont == Font.caption)
    }

    @Test("text block tops out next to the poster, and centres without an overview")
    func verticalAlignmentFollowsOverview() {
        #expect(CollectionItemRow.verticalAlignment(hasOverview: true) == .top)
        #expect(CollectionItemRow.verticalAlignment(hasOverview: false) == .center)
    }

    @Test("row reads its metrics instead of hardcoding poster and font sizes")
    func rowIsMetricsDriven() throws {
        let source = try sourceFile("Sodalite/Features/Detail/CollectionDetailView.swift")
        #expect(!source.contains("frame(width: 80, height: 120)"))
        #expect(source.contains("metrics.listPosterSize"))
        #expect(source.contains("metrics.listTitleFont"))
        #expect(source.contains("metrics.listOverviewFont"))
        #expect(source.contains("lineLimit(3)"))
    }

    @Test("metadata chips wrap instead of shrinking past legibility")
    func metadataWrapsInsteadOfScaling() throws {
        let source = try sourceFile("Sodalite/Features/Detail/CollectionDetailView.swift")
        #expect(source.contains("FlowLayout(spacing: 10)"))
        #expect(!source.contains("minimumScaleFactor"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
