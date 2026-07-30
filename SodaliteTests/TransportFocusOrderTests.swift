import Testing
@testable import Sodalite

@Suite("Transport focus order")
@MainActor
struct TransportFocusOrderTests {
    private func order(isInsideIntro: Bool = false, episodeCount: Int = 1, chapterCount: Int = 0,
                       hasAudioTracks: Bool = true, hasSubtitles: Bool = true,
                       isPiPAvailable: Bool = false, showsStats: Bool = false) -> [PlayerViewModel.ControlsFocus] {
        PlayerViewModel.transportFocusOrder(
            isInsideIntro: isInsideIntro, episodeCount: episodeCount, chapterCount: chapterCount,
            hasAudioTracks: hasAudioTracks, hasSubtitles: hasSubtitles,
            isPiPAvailable: isPiPAvailable, showsStats: showsStats)
    }

    @Test("restart leads the order and is always present")
    func restartAlwaysFirst() {
        #expect(order().first == .restartButton)
        #expect(order(isInsideIntro: true, episodeCount: 12, isPiPAvailable: true, showsStats: true).first == .restartButton)
        #expect(order(hasAudioTracks: false, hasSubtitles: false).first == .restartButton)
    }

    @Test("skip intro sits between restart and the track buttons")
    func introPosition() {
        #expect(order(isInsideIntro: true) == [.restartButton, .skipIntroButton, .audioButton, .subtitleButton, .speedButton, .pictureButton])
    }

    @Test("a bare stream still has restart, speed and picture")
    func minimalOrder() {
        #expect(order(hasAudioTracks: false, hasSubtitles: false) == [.restartButton, .speedButton, .pictureButton])
    }

    @Test("chapters are suppressed on series episodes, mirroring TransportBar")
    func chapterGate() {
        #expect(order(episodeCount: 12, chapterCount: 40).contains(.chapterButton) == false)
        #expect(order(episodeCount: 12, chapterCount: 40).contains(.episodeButton))
        #expect(order(episodeCount: 1, chapterCount: 40).contains(.chapterButton))
    }

    @Test("optional trailing buttons appear only when enabled")
    func trailingButtons() {
        #expect(order().contains(.pipButton) == false)
        #expect(order().contains(.infoButton) == false)
        #expect(Array(order(isPiPAvailable: true, showsStats: true).suffix(2)) == [.pipButton, .infoButton])
    }
}
