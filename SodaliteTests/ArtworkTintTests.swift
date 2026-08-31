import Testing
import SwiftUI
import UIKit
@testable import Sodalite

/// The portrait page tint (Sodalite#95). The first build averaged the artwork's bottom edge into one
/// pixel and capped its saturation, which reads as grey or brown on nearly every backdrop: at the
/// brightness the page has to hold for white text, a dark colour needs a high HSB saturation before
/// it is a colour at all. What is pinned here is the pair of promises that replaced the cap, because
/// they pull in opposite directions: a strip that carries colour gets it lifted until it is visible,
/// and a strip that carries none is never given one.
struct ArtworkTintTests {

    // MARK: helpers

    private func components(_ color: Color) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return (hue, saturation, brightness)
    }

    /// WCAG relative luminance, to check the tint against the white body text that sits on it.
    private func contrastWithWhite(_ color: Color) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: nil)
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        return 1.05 / (luminance + 0.05)
    }

    private func reading(
        hue: CGFloat = 0,
        saturation: CGFloat = 0,
        brightness: CGFloat = 0.5,
        dominantHue: CGFloat = 0,
        chromaticSaturation: CGFloat = 0,
        coherence: CGFloat = 0,
        chroma: CGFloat = 0
    ) -> ArtworkStripReading {
        ArtworkStripReading(
            hue: hue, saturation: saturation, brightness: brightness,
            dominantHue: dominantHue, chromaticSaturation: chromaticSaturation,
            coherence: coherence, chroma: chroma
        )
    }

    /// An image whose bottom eighth is `bottom` and whose remaining seven eighths are `top`, so the
    /// strip the tint reads is known exactly and the rest of the frame must not reach it.
    private func artwork(top: UIColor, bottom: UIColor, size: CGSize = CGSize(width: 320, height: 180)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            top.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            bottom.setFill()
            let stripHeight = (size.height / 8).rounded(.up)
            context.fill(CGRect(x: 0, y: size.height - stripHeight, width: size.width, height: stripHeight))
        }
    }

    // MARK: the lift

    /// The Matrix case from the measured corpus: the strip averages to a near-grey (saturation 0.045)
    /// while its coloured pixels agree on one teal (chromatic saturation 0.435). The average alone
    /// produced #3A3C3D, a dead grey; the page has to end up teal.
    @Test func aStripWhoseColourIsOutvotedByGreyStillPaintsThatColour() {
        let palette = ArtworkTint.palette(for: reading(
            hue: 0.524, saturation: 0.045, brightness: 0.608,
            dominantHue: 0.526, chromaticSaturation: 0.435, coherence: 0.59, chroma: 0.053
        ))
        let near = components(palette.near)
        #expect(abs(near.hue - 0.526) < 0.01)
        // Tolerance because the value round-trips through UIColor's 8-bit components on the way back.
        #expect(near.saturation >= 0.449, "grey-outvoted teal came out at saturation \(near.saturation)")
    }

    /// The lift has a ceiling in taste, not in contrast, so a strongly graded backdrop keeps more of
    /// its saturation than the old 0.55 cap allowed but does not become neon.
    @Test func aSaturatedStripKeepsItsColourWithoutRunningAway() {
        let palette = ArtworkTint.palette(for: reading(
            hue: 0.101, saturation: 0.685, brightness: 0.510,
            dominantHue: 0.102, chromaticSaturation: 0.710, coherence: 0.99, chroma: 0.350
        ))
        let near = components(palette.near)
        #expect(near.saturation > 0.55)
        #expect(near.saturation <= 0.85)
    }

    /// The lift may make the artwork's colour visible; it may not claim a stronger colour than the
    /// coloured pixels themselves have, beyond the floor.
    @Test func theLiftNeverExceedsWhatTheColouredPixelsMeasure() {
        for chromaticSaturation in [CGFloat(0.5), 0.6, 0.7, 0.9] {
            let palette = ArtworkTint.palette(for: reading(
                hue: 0.6, saturation: 0.2, brightness: 0.4,
                dominantHue: 0.6, chromaticSaturation: chromaticSaturation, coherence: 0.9, chroma: 0.2
            ))
            let near = components(palette.near)
            #expect(near.saturation <= max(chromaticSaturation, 0.45) + 0.001,
                    "lifted to \(near.saturation) from a measured \(chromaticSaturation)")
        }
    }

    // MARK: the gate

    /// An achromatic backdrop (Arrival in the corpus, chroma 0.000) has no hue to recover. Painting
    /// the page from that would be inventing a colour the artwork does not have.
    @Test func aStripWithNoColourInItStaysNeutral() {
        let palette = ArtworkTint.palette(for: reading(
            hue: 0, saturation: 0, brightness: 0.690,
            dominantHue: 0, chromaticSaturation: 0, coherence: 0, chroma: 0
        ))
        #expect(components(palette.near).saturation < 0.01)
    }

    /// The trap the chroma gate exists for: a letterboxed backdrop whose bottom eighth is the black
    /// bar (The Lord of the Rings in the corpus) reports a coherence of 0.89 and a chromatic
    /// saturation of 0.72, both of them JPEG noise in a black field. Coherence alone would have
    /// painted the page a saturated colour out of nothing.
    @Test func blackBarNoiseDoesNotPassAsColour() {
        let palette = ArtworkTint.palette(for: reading(
            hue: 0, saturation: 0, brightness: 0.004,
            dominantHue: 0.163, chromaticSaturation: 0.721, coherence: 0.89, chroma: 0.0004
        ))
        #expect(components(palette.near).saturation < 0.01)
    }

    /// Hues that genuinely disagree keep the plain average and the old cap: their chroma-weighted
    /// mean points at a hue no part of the strip actually is.
    @Test func disagreeingHuesKeepThePlainAverage() {
        let palette = ArtworkTint.palette(for: reading(
            hue: 0.583, saturation: 0.058, brightness: 0.545,
            dominantHue: 0.574, chromaticSaturation: 0.309, coherence: 0.25, chroma: 0.121
        ))
        let near = components(palette.near)
        #expect(abs(near.hue - 0.583) < 0.01)
        #expect(near.saturation < 0.1)
    }

    // MARK: what the page owes the text on it

    /// The tint carries white body text on every path through the gate, lifted or not. The clamp is
    /// what buys this, and saturating a colour at a fixed HSB brightness lowers its luminance, so the
    /// lift can only help.
    @Test func everyTintClearsTheContrastTheBodyTextNeeds() {
        let corners: [ArtworkStripReading] = [
            reading(hue: 0.101, saturation: 0.685, brightness: 0.99,
                    dominantHue: 0.101, chromaticSaturation: 0.9, coherence: 1, chroma: 0.5),
            reading(hue: 0.6, saturation: 0.9, brightness: 0.99,
                    dominantHue: 0.6, chromaticSaturation: 0.95, coherence: 1, chroma: 0.6),
            reading(hue: 0, saturation: 0, brightness: 1),
            reading(hue: 0.3, saturation: 0.5, brightness: 0.001,
                    dominantHue: 0.3, chromaticSaturation: 0.6, coherence: 0.9, chroma: 0.3),
        ]
        for corner in corners {
            let palette = ArtworkTint.palette(for: corner)
            #expect(contrastWithWhite(palette.near) >= 7,
                    "near end fell to \(contrastWithWhite(palette.near)):1")
            #expect(contrastWithWhite(palette.far) >= 7)
        }
    }

    /// The far end is the same colour deepened, never black: the page keeps its colour to the bottom.
    @Test func theFarEndKeepsTheHue() {
        let palette = ArtworkTint.palette(for: reading(
            hue: 0.6, saturation: 0.5, brightness: 0.4,
            dominantHue: 0.6, chromaticSaturation: 0.6, coherence: 0.9, chroma: 0.2
        ))
        let near = components(palette.near), far = components(palette.far)
        #expect(abs(near.hue - far.hue) < 0.01)
        #expect(far.brightness < near.brightness)
        #expect(far.brightness > 0)
    }

    // MARK: reading a real image

    /// The strip is the bottom eighth, and the seven eighths above it must not reach the page colour:
    /// a bright top over a teal bottom is the shape that a full-frame average gets wrong.
    @Test func theReadingComesFromTheBottomEighthOnly() throws {
        let image = artwork(top: .white, bottom: UIColor(hue: 0.5, saturation: 0.8, brightness: 0.5, alpha: 1))
        let strip = try #require(ArtworkTint.stripReading(of: image))
        #expect(abs(strip.hue - 0.5) < 0.02)
        #expect(strip.saturation > 0.7)
        #expect(strip.coherence > 0.95)
        let near = components(ArtworkTint.palette(for: strip).near)
        #expect(abs(near.hue - 0.5) < 0.02)
        #expect(near.brightness <= 0.24)
    }

    /// Two opposed hues in equal measure cancel: the strip has plenty of chroma but points nowhere,
    /// which is the case the coherence gate is for.
    @Test func opposedHuesReportNoAgreement() throws {
        let size = CGSize(width: 320, height: 180)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let stripHeight = (size.height / 8).rounded(.up)
            UIColor(hue: 0.0, saturation: 0.9, brightness: 0.6, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: size.height - stripHeight, width: size.width / 2, height: stripHeight))
            UIColor(hue: 0.5, saturation: 0.9, brightness: 0.6, alpha: 1).setFill()
            context.fill(CGRect(x: size.width / 2, y: size.height - stripHeight, width: size.width / 2, height: stripHeight))
        }
        let strip = try #require(ArtworkTint.stripReading(of: image))
        #expect(strip.chroma > 0.2, "the strip does carry colour, it just does not agree")
        #expect(strip.coherence < 0.2)
        #expect(components(ArtworkTint.palette(for: strip).near).saturation < 0.2)
    }

    /// A black strip reads as black, not as a hue pulled out of rounding.
    @Test func aBlackStripReadsAsBlack() throws {
        let image = artwork(top: .white, bottom: .black)
        let strip = try #require(ArtworkTint.stripReading(of: image))
        #expect(strip.chroma < 0.02)
        #expect(components(ArtworkTint.palette(for: strip).near).saturation < 0.01)
    }
}
