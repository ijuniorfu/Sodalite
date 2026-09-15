import Testing
import SwiftUI
import UIKit
@testable import Sodalite

/// The detail page's first block is bottom-aligned inside a viewport-tall page, so everything it
/// holds comes out of one fixed band. Sodalite#146 put the synopsis in there, and a teaser whose
/// height is not pinned is two known defects at once: a block that grows when the fetch lands
/// pushes the action row down after first paint (Sodalite#15), and a panel whose height varies
/// within one mode opens the page at a different scroll offset every time (the episode-vs-series
/// landing).
///
/// Measured on the tvOS simulator against real font metrics, hosted rather than estimated.
@MainActor
struct DetailHeroBudgetTests {

    /// 1080 pt screen less the tvOS title-safe inset top and bottom.
    private let titleSafeBand: CGFloat = 1080 - 2 * 60
    /// 1920 pt screen less `LayoutMetrics.rowInset` on both sides: the panel's outer width.
    private let panelWidth: CGFloat = 1920 - 2 * 50
    /// Inside the panel's own 30 pt padding.
    private var textWidth: CGFloat { panelWidth - 2 * 30 }

    /// Roughly a paragraph, long enough to overrun three lines at 1760 pt.
    private let longSynopsis = String(
        repeating: "American college football coach Ted Lasso heads to London to manage a struggling Premier League side he knows nothing about. ",
        count: 4
    )

    private func height(_ view: some View, width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: view.frame(width: width))
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: 1080)
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    // MARK: - The reserve

    /// The whole point of the component: an overview that has not arrived holds exactly the space
    /// the arriving text will take, so nothing below it moves when it lands.
    @Test func aPendingSynopsisReservesWhatTheTextWillTake() {
        let landed = height(DetailHeroSynopsis(text: longSynopsis), width: textWidth)
        let pending = height(DetailHeroSynopsis(text: nil, isPending: true), width: textWidth)
        #expect(abs(landed - pending) < 1)
    }

    /// Three lines whatever the text does, so a one-line synopsis and a five-line one open the page
    /// at the same scroll offset.
    @Test func oneLineAndManyLinesTakeTheSameHeight() {
        let short = height(DetailHeroSynopsis(text: "A short one."), width: textWidth)
        let long = height(DetailHeroSynopsis(text: longSynopsis), width: textWidth)
        #expect(abs(short - long) < 1)
    }

    /// Three lines of `.body` and nothing else: the component contributes no padding, no background
    /// and no minimum of its own, so the panel's own spacing is the only gap around it.
    ///
    /// Pinned against the primitive rather than against arithmetic, because the arithmetic is off.
    /// Measured on tvOS 26: the block is 107.0 pt where 3 x `UIFont.body.lineHeight` is 103.82, so
    /// SwiftUI carries about 1.06 pt per line over the font's own line height. Worth knowing before
    /// budgeting any other multi-line block from the font table.
    @Test func theReserveIsExactlyThreeBodyLines() {
        let bare = Text(longSynopsis)
            .font(.body)
            .lineLimit(3, reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        let measured = height(DetailHeroSynopsis(text: longSynopsis), width: textWidth)
        #expect(abs(measured - height(bare, width: textWidth)) < 1)
        #expect(measured > 3 * UIFont.preferredFont(forTextStyle: .body).lineHeight)
    }

    /// A title that settles without a synopsis collapses the block instead of keeping three blank
    /// lines: the reserve exists for a fetch in flight, not for an absent fact.
    @Test func aSettledEmptySynopsisTakesNoSpace() {
        #expect(height(DetailHeroSynopsis(text: nil, isPending: false), width: textWidth) == 0)
    }

    // MARK: - The band

    /// The first page with the teaser in it, against the band it has to live in. Each constant is
    /// read off the shipping code rather than guessed: 200 pt hero gradient
    /// (`DetailContentOverlay.gradientWithHero`, the logo rides it as an overlay and costs nothing),
    /// the panel's 30 pt padding and 16 pt row spacing (`glassPanel`), 24 pt to the action row
    /// (the primary slot's VStack), and the fold band below it (`ScrollHintPolicy`).
    @Test func theFirstPageStillFitsTheTitleSafeBand() {
        let subheadline = UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
        let caption = UIFont.preferredFont(forTextStyle: .caption1).lineHeight
        let callout = UIFont.preferredFont(forTextStyle: .callout).lineHeight

        let heroGradient: CGFloat = 200
        // Metadata line: the tallest segment is the certification box, caption plus its 3 pt inset.
        let metadataLine = max(subheadline, caption + 6)
        let synopsis = height(DetailHeroSynopsis(text: longSynopsis), width: textWidth)
        // glassPanel: 30 pt padding, the metadata line, then the teaser 16 pt below it. The genre
        // line left the panel with the studios in Sodalite#146 round 2, both are in More Details.
        let panel = 2 * 30 + metadataLine + 16 + synopsis
        // GlassActionButtonLabel: callout plus 12 pt vertical padding. The resume bar is drawn
        // inside that block and is layout-neutral by construction.
        let actionRow = callout + 2 * 12
        let foldBand = ScrollHintPolicy.primaryBottomInset(reservesHint: true)

        let firstPage = heroGradient + panel + 24 + actionRow + foldBand
        #expect(firstPage <= titleSafeBand,
                "first page \(firstPage) pt overruns the \(titleSafeBand) pt title-safe band")
    }
}
