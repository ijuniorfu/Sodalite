import Testing
@testable import Sodalite

@Suite("Buffered progress mapping")
struct BufferedProgressTests {
    @Test("maps position over duration into 0...1")
    func normal() {
        #expect(PlayerViewModel.bufferedProgressValue(bufferedPosition: 300, duration: 1200, isLive: false) == 0.25)
    }

    @Test("clamps above 1")
    func clampsHigh() {
        #expect(PlayerViewModel.bufferedProgressValue(bufferedPosition: 5000, duration: 1200, isLive: false) == 1)
    }

    @Test("zero when duration is non-positive")
    func zeroDuration() {
        #expect(PlayerViewModel.bufferedProgressValue(bufferedPosition: 300, duration: 0, isLive: false) == 0)
    }

    @Test("zero for live sessions")
    func zeroLive() {
        #expect(PlayerViewModel.bufferedProgressValue(bufferedPosition: 300, duration: 1200, isLive: true) == 0)
    }
}
