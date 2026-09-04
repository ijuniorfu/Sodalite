import Testing
import SwiftUI
import UIKit
@testable import Sodalite

/// The Top Shelf accent mirror ships `RGBColor.hex` through the shared defaults and the extension
/// rebuilds the colour from it, so a lossy round trip would silently recolour every resume bar.
struct AccentHexTests {

    @Test("every preset's control colour survives the round trip")
    func presetsRoundTrip() {
        for preset in AccentPreset.allCases {
            let control = preset.palette.control
            #expect(RGBColor(hex: control.hex) == control,
                    "\(preset.rawValue) changed when packed and unpacked")
        }
    }

    @Test("packing reproduces the literal the palette was written with")
    func knownValues() {
        #expect(RGBColor(hex: 0x007AFF).hex == 0x007AFF)
        #expect(RGBColor(hex: 0xEE91AD).hex == 0xEE91AD)
        #expect(RGBColor(hex: 0x000000).hex == 0x000000)
        #expect(RGBColor(hex: 0xFFFFFF).hex == 0xFFFFFF)
    }

    /// Channels are stored as Double, so the packer has to round rather than truncate; without it
    /// 0xFF comes back as 0xFE and white drifts grey.
    @Test("full-scale channels do not lose a step to truncation")
    func fullScaleChannels() {
        #expect(RGBColor(hex: 0xFF0000).hex == 0xFF0000)
        #expect(RGBColor(hex: 0x00FF00).hex == 0x00FF00)
        #expect(RGBColor(hex: 0x0000FF).hex == 0x0000FF)
    }

    /// The default blue is written down three times: in the preset table, in the extension's
    /// fallback, and in the asset catalogue. The extension cannot import the preset table (that is
    /// the point of the mirror) and the asset is what Xcode stamps on the app, so the duplication
    /// stays. What did not exist until Sodalite#106 was anything that NOTICED them parting: both
    /// copies carry a comment claiming the equality, and a comment does not fail a build.
    @Test("the Top Shelf fallback is the accent it says it mirrors")
    func topShelfFallbackMirrorsSystemBlue() {
        #expect(TopShelfAccent.fallback == AccentPreset.systemBlue.palette.control.hex,
                "the extension would paint a resume bar in a blue the app never uses")
    }

    @Test("the AccentColor asset is the accent the app defaults to")
    func accentAssetMatchesSystemBlue() throws {
        let asset = try #require(UIColor(named: "AccentColor"),
                                 "AccentColor.colorset is missing from the host bundle")
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        asset.resolvedColor(with: UITraitCollection { $0.userInterfaceStyle = .dark })
            .getRed(&red, green: &green, blue: &blue, alpha: nil)
        // Packed the way `RGBColor.hex` does it, rounding rather than truncating.
        func channel(_ value: CGFloat) -> UInt32 { UInt32(min(255, max(0, (Double(value) * 255).rounded()))) }
        let packed = channel(red) << 16 | channel(green) << 8 | channel(blue)
        #expect(packed == AccentPreset.systemBlue.palette.control.hex,
                "the asset resolves to \(String(format: "%06X", packed))")
    }
}
