import Testing
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
}
