import Testing
import SwiftUI
import UIKit
@testable import Sodalite

/// Sodalite#104 round 2: the two findings from the device round that are about the rail's chrome
/// rather than its geometry, pinned as numbers.
///
/// Both were one mistake made twice: a size measured for the phone and then drawn on the television.
/// The row was 30 pt tall on both platforms, which covers the phone's `.caption` line and falls 7 pt
/// short of tvOS `.callout`, and the press readout was a two-line column of 66 pt centred on that
/// row, so it spent 18 pt upwards, into the 4 pt that separated the row from a scrub knob which is
/// 22 pt wide at exactly the moment the readout exists.
@Suite("The live rail's chrome (Sodalite#104 round 2)")
struct LiveRailChromeTests {

    private func size(_ view: some View) -> CGSize {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 200)
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
    }

    // MARK: - A row is as tall as the line it draws

    @Test func theRowCoversItsOwnTextLine() {
        #if os(tvOS)
        let line = UIFont.preferredFont(forTextStyle: .callout).lineHeight
        #else
        let line = UIFont.preferredFont(forTextStyle: .caption1).lineHeight
        #endif
        #expect(LiveRailLabels.defaultRowHeight >= line)
    }

    /// A readout taller than its row spends the difference upwards, where the track is.
    @Test func aPressReadoutFitsInsideItsRow() {
        let single = size(SeekReadoutView(readout: .press(seconds: 10, count: 1, direction: -1)))
        let burst = size(SeekReadoutView(readout: .press(seconds: 10, count: 4, direction: -1)))
        #expect(single.height <= LiveRailLabels.defaultRowHeight)
        #expect(burst.height <= LiveRailLabels.defaultRowHeight)
        // The burst count belongs beside the glyph, not under it: it may cost width, never height.
        #expect(burst.height == single.height)
        #expect(burst.width > single.width)
    }

    @Test func aHoldReadoutFitsInsideItsRow() {
        #expect(size(SeekReadoutView(readout: .hold(rate: 96, direction: 1))).height
                <= LiveRailLabels.defaultRowHeight)
    }

    // MARK: - The badge says its status in a colour the word can carry

    private func resolved(_ color: Color) -> RGBColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ value: CGFloat) -> UInt32 {
            UInt32(min(255, max(0, (value * 255).rounded())))
        }
        return RGBColor(hex: channel(r) << 16 | channel(g) << 8 | channel(b))
    }

    /// `restFillStrong` is white at 0.12, blended in the gamma-encoded space the colours are
    /// authored in, over whatever the picture leaves behind it.
    private func pill(overGround ground: Double) -> RGBColor {
        let level = 0.12 + 0.88 * ground
        let channel = UInt32((min(1, max(0, level)) * 255).rounded())
        return RGBColor(hex: channel << 16 | channel << 8 | channel)
    }

    /// The badge sits low in the control scrim, which is at least 0.7 black there, so the brightest
    /// ground white artwork can push through its pill is 0.3.
    @Test func theBadgeWordIsReadableOnItsOwnPill() {
        let green = resolved(Color.Theme.success)
        for ground in [0.0, 0.3] {
            let ratio = green.contrastRatio(with: pill(overGround: ground))
            #expect(ratio >= 3.0, "the LIVE word reads at \(ratio):1 over ground \(ground)")
        }
    }

    /// Why the colour is on the word and not on the fill, kept as a test so the number that decided
    /// it stays attached to it: the filled pill this replaced cannot carry a white label.
    @Test func aFilledStatusPillCouldNotHaveCarriedItsLabel() {
        let green = resolved(Color.Theme.success)
        #expect(RGBColor.white.contrastRatio(with: green) < 3.0)
    }
}
