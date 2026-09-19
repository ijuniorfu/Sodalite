import Testing
import SwiftUI
import UIKit
@testable import Sodalite

/// Sodalite#151: the seek readout on the stored-title transport, where the numbers are not the live
/// rail's.
///
/// The readout stands beside the scrub clock, and on this bar that clock comes in two sizes: 22 pt
/// under a trickplay frame, 56 pt in the middle of the screen when the server carries no frames. A
/// skip glyph is taller than the line it sits beside at its own size, so the first of those has to be
/// a pre-sized row and the second has to draw its glyph smaller. Both are numbers, so both are here.
@Suite("The stored-title seek readout (Sodalite#151)")
struct SeekReadoutChromeTests {

    private func size(_ view: some View) -> CGSize {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 200)
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
    }

    /// Every readout the bar can draw: a lone press, a burst, and a hold at its ceiling.
    private let readouts: [SeekReadout] = [
        .press(seconds: 10, count: 1, direction: -1),
        .press(seconds: 90, count: 1, direction: 1),
        .press(seconds: 30, count: 12, direction: -1),
        .hold(rate: 15, direction: -1),
        .hold(rate: 240, direction: 1),
    ]

    // MARK: - Under a trickplay frame

    /// The card's clock row is sized before anything appears in it, because what appears in it arrives
    /// mid-gesture. A row that grows on the press that draws the first glyph moves the frame above it
    /// at the one moment the frame is being read.
    @Test func theCardClockRowHoldsEveryReadoutItCanDraw() {
        let font = Font.system(size: TransportBar.cardClockSize, weight: .semibold)
        for readout in readouts {
            let drawn = size(SeekReadoutView(readout: readout, font: font)).height
            #expect(drawn <= TransportBar.cardClockRowHeight,
                    "\(readout) draws \(drawn) in a row of \(TransportBar.cardClockRowHeight)")
        }
    }

    @Test func theCardClockRowHoldsItsOwnClock() {
        let clock = size(Text(verbatim: "01:23:45")
            .font(.system(size: TransportBar.cardClockSize, weight: .semibold))).height
        #expect(clock <= TransportBar.cardClockRowHeight)
    }

    /// The row is derived rather than remembered, and the point of deriving it is that it lands above
    /// the text it was once guessed from. The literal this replaced was 28 pt of a 34 pt card.
    @Test func theCardClockRowIsTallerThanItsTextAlone() {
        let clock = size(Text(verbatim: "01:23:45")
            .font(.system(size: TransportBar.cardClockSize, weight: .semibold))).height
        #expect(TransportBar.cardClockRowHeight >= clock)
    }

    // MARK: - Without one

    /// This is the one row on the bar that is NOT pre-sized, and it gets away with it because its
    /// glyph is drawn at half the clock's size: shorter than the clock's own line, so it cannot move
    /// anything by appearing.
    @Test func theCentredClockIsNotMovedByItsReadout() {
        let clock = size(Text(verbatim: "01:23:45")
            .font(.system(size: TransportBar.centredClockSize, weight: .medium))).height
        let glyphFont = Font.system(size: TransportBar.centredClockGlyphSize, weight: .medium)
        for readout in readouts {
            let drawn = size(SeekReadoutView(readout: readout, font: glyphFont)).height
            #expect(drawn <= clock,
                    "\(readout) draws \(drawn) beside a \(clock) pt clock")
        }
    }

    /// The reason the centred clock gets a smaller glyph at all, kept as the measurement that decided
    /// it: a glyph is taller than the line it stands beside at every size, so at the clock's own size
    /// it would lift a row that nothing is holding.
    ///
    /// Width is deliberately not the argument, though it reads like one. Measured, it is the wrong way
    /// round: a full-size readout is 133.5 x 72.5 against this clock's 222.5 x 67.0, so it would have
    /// fitted beside the time comfortably and lifted it by 5.5 pt anyway.
    @Test func aFullSizeGlyphWouldHaveLiftedTheCentredClock() {
        let font = Font.system(size: TransportBar.centredClockSize, weight: .medium)
        let clock = size(Text(verbatim: "01:23:45").font(font))
        let fullSize = size(SeekReadoutView(readout: .press(seconds: 30, count: 4, direction: -1),
                                            font: font))
        #expect(fullSize.height > clock.height,
                "a full-size readout draws \(fullSize.height) beside a \(clock.height) pt clock")
        #expect(fullSize.width < clock.width)
    }

    // MARK: - The burst count costs width, never height

    /// Same rule the live rail holds, at this bar's sizes: the count sits beside the glyph, so a
    /// fourth press widens the readout and never lifts it into the frame above.
    @Test func aBurstCountCostsWidthAndNotHeight() {
        for pointSize in [TransportBar.cardClockSize, TransportBar.centredClockGlyphSize] {
            let font = Font.system(size: pointSize, weight: .semibold)
            let single = size(SeekReadoutView(readout: .press(seconds: 10, count: 1, direction: -1),
                                              font: font))
            let burst = size(SeekReadoutView(readout: .press(seconds: 10, count: 9, direction: -1),
                                             font: font))
            #expect(burst.height == single.height)
            #expect(burst.width > single.width)
        }
    }

    // MARK: - The measurement both bars ask

    /// `SeekReadoutMetrics` is what replaced two literals, one per bar, and a row shorter than its
    /// glyph spends the difference upwards where the track is.
    @Test func theMeasuredRowCoversEveryGlyphAtItsOwnSize() {
        for pointSize in [TransportBar.cardClockSize, TransportBar.centredClockGlyphSize] {
            let height = SeekReadoutMetrics.rowHeight(
                symbol: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold),
                lineHeight: UIFont.systemFont(ofSize: pointSize, weight: .semibold).lineHeight)
            for name in SeekReadout.drawableGlyphNames {
                let drawn = size(Image(systemName: name)
                    .font(.system(size: pointSize, weight: .semibold))).height
                #expect(drawn <= height, "\(name) at \(pointSize) draws \(drawn) in a row of \(height)")
            }
        }
    }

    /// A line taller than every glyph still gets a row it fits in: the measurement takes the larger of
    /// the two, which is what the centred clock relies on from the other side.
    @Test func theMeasuredRowNeverFallsShortOfItsTextLine() {
        let line = UIFont.systemFont(ofSize: 56, weight: .medium).lineHeight
        let height = SeekReadoutMetrics.rowHeight(
            symbol: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium),
            lineHeight: line)
        #expect(height >= line)
    }
}
