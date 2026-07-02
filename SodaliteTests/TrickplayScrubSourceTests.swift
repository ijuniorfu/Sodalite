import Testing
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

/// #93 startup: the warm-seed extraction pulls megabytes over the same link the producer
/// needs; during startup/recovery that contention tipped the first segment past CoreMedia's
/// ~4 s loader timeout (plays 1-2 s, loader dies, item reload). Warm only on a healthy buffer.
struct WarmSeedGateTests {
    @Test("warm-seed requires a healthy forward buffer")
    func warmSeedGate() {
        #expect(!ScrubPreviewProvider.shouldWarm(forwardBufferSeconds: nil))
        #expect(!ScrubPreviewProvider.shouldWarm(forwardBufferSeconds: 0.0))
        #expect(!ScrubPreviewProvider.shouldWarm(forwardBufferSeconds: 2.9))
        #expect(ScrubPreviewProvider.shouldWarm(forwardBufferSeconds: 3.0))
        #expect(ScrubPreviewProvider.shouldWarm(forwardBufferSeconds: 7.5))
    }
}
