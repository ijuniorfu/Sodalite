import CoreGraphics
import Testing
@testable import Sodalite

@Suite("Background picker layout")
struct BackgroundPickerLayoutTests {
    @Test("tvOS uses three uniform columns")
    func tvOSColumns() {
        #expect(BackgroundPickerLayout.tvOSColumnCount == 3)
        #expect(BackgroundPickerLayout.columnSpacing == 24)
    }

    @Test("tiles reserve stable preview and metadata regions")
    func tileRegions() {
        #expect(
            abs(BackgroundPickerLayout.previewAspectRatio - 16.0 / 9.0)
                < 0.0001
        )
        #expect(BackgroundPickerLayout.tvOSMetadataHeight == 144)
        #expect(BackgroundPickerLayout.iOSMetadataHeight == 68)
        #if os(tvOS)
        #expect(BackgroundPickerLayout.metadataHeight == 144)
        #else
        #expect(BackgroundPickerLayout.metadataHeight == 68)
        #endif
    }
}
