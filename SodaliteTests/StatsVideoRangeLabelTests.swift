import Testing
import AetherEngine
@testable import Sodalite

/// AE#459. The dynamic range row names the source and, when the chain changes it, what is presented.
@Suite("Stats video range label")
struct StatsVideoRangeLabelTests {
    @Test("A Profile 7 presented as Dolby Vision names the Profile 8.1 it is served as")
    func profile7ConvertedNamesProfile81() {
        #expect(StatsOverlayView.videoRangeLabel(
            source: .dolbyVision, presented: .dolbyVision, dvProfile: 7,
            conversion: .profile7ToProfile81) == "Dolby Vision P7 → P8.1")
    }

    @Test("A Dolby Vision source played without a conversion keeps the plain label")
    func unconvertedDolbyVisionHasNoArrow() {
        #expect(StatsOverlayView.videoRangeLabel(
            source: .dolbyVision, presented: .dolbyVision, dvProfile: 8, conversion: nil)
            == "Dolby Vision P8")
    }

    // The engine converts only for a display presenting Dolby Vision, but the label must not claim
    // P8.1 if the presented format says otherwise.
    @Test("A clamped Profile 7 names the clamp, not the conversion")
    func clampWinsOverConversion() {
        #expect(StatsOverlayView.videoRangeLabel(
            source: .dolbyVision, presented: .sdr, dvProfile: 7,
            conversion: .profile7ToProfile81) == "Dolby Vision P7 → SDR")
    }

    @Test("A Dolby Vision source presented through its HDR10+ layer says HDR10+")
    func dolbyVisionToHDR10Plus() {
        #expect(StatsOverlayView.videoRangeLabel(
            source: .dolbyVision, presented: .hdr10Plus, dvProfile: 7, conversion: nil)
            == "Dolby Vision P7 → HDR10+")
    }
}
