import Testing
import CoreGraphics
@testable import Sodalite

struct TrickplayScrubSourceTests {
    private func tileSet() -> TrickplayTileSet? {
        let info = TrickplayInfo(width: 320, height: 180, tileWidth: 10, tileHeight: 10,
                                 thumbnailCount: 100, interval: 10000, bandwidth: nil)
        return TrickplayTileSet(trickplay: ["s": ["320": info]], mediaSourceID: "s", targetWidth: 320)
    }

    @Test("server source only when preferred AND tiles exist")
    func decision() {
        #expect(PlayerViewModel.shouldUseServerTrickplay(preferServer: true, tileSet: tileSet()) == true)
        #expect(PlayerViewModel.shouldUseServerTrickplay(preferServer: true, tileSet: nil) == false)
        #expect(PlayerViewModel.shouldUseServerTrickplay(preferServer: false, tileSet: tileSet()) == false)
        #expect(PlayerViewModel.shouldUseServerTrickplay(preferServer: false, tileSet: nil) == false)
    }
}

@MainActor
struct ScrubPreviewResolutionTests {

    private func dummyImage() -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    @Test("cache hit returns the cache image and is consulted once")
    func cacheHit() async {
        let provider = ScrubPreviewProvider()
        let img = dummyImage()
        var cacheCalls = 0
        provider.configure(extractor: nil,
                           cacheThumbnail: { _, _ in cacheCalls += 1; return img },
                           enabled: true)
        let result = await provider.resolveThumbnail(seconds: 10)
        #expect(result != nil)
        #expect(cacheCalls == 1)
    }

    @Test("cache miss with no extractor yields nil")
    func cacheMissNoExtractor() async {
        let provider = ScrubPreviewProvider()
        provider.configure(extractor: nil,
                           cacheThumbnail: { _, _ in nil },
                           enabled: true)
        let result = await provider.resolveThumbnail(seconds: 10)
        #expect(result == nil)
    }

    @Test("server source takes precedence and is used")
    func serverSource() async {
        let provider = ScrubPreviewProvider()
        let img = dummyImage()
        var serverCalls = 0
        provider.configure(serverThumbnail: { _ in serverCalls += 1; return img },
                           enabled: true)
        let result = await provider.resolveThumbnail(seconds: 10)
        #expect(result != nil)
        #expect(serverCalls == 1)
    }

    @Test("reset clears the cache source")
    func resetClearsCache() async {
        let provider = ScrubPreviewProvider()
        var cacheCalls = 0
        provider.configure(extractor: nil,
                           cacheThumbnail: { _, _ in cacheCalls += 1; return self.dummyImage() },
                           enabled: true)
        provider.reset()
        let result = await provider.resolveThumbnail(seconds: 10)
        #expect(result == nil)
        #expect(cacheCalls == 0)
    }
}