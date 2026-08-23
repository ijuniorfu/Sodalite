import Testing
@testable import Sodalite

@Suite("Transport focus order")
@MainActor
struct TransportFocusOrderTests {
    private func order(hasSkippableSegment: Bool = false, episodeCount: Int = 1, chapterCount: Int = 0,
                       hasAudioTracks: Bool = true, hasSubtitles: Bool = true,
                       isPiPAvailable: Bool = false, showsStats: Bool = false) -> [PlayerViewModel.ControlsFocus] {
        PlayerViewModel.transportFocusOrder(
            hasSkippableSegment: hasSkippableSegment, episodeCount: episodeCount, chapterCount: chapterCount,
            hasAudioTracks: hasAudioTracks, hasSubtitles: hasSubtitles,
            isPiPAvailable: isPiPAvailable, showsStats: showsStats)
    }

    @Test("restart leads the order and is always present")
    func restartAlwaysFirst() {
        #expect(order().first == .restartButton)
        #expect(order(hasSkippableSegment: true, episodeCount: 12, isPiPAvailable: true, showsStats: true).first == .restartButton)
        #expect(order(hasAudioTracks: false, hasSubtitles: false).first == .restartButton)
    }

    @Test("the skip button sits between restart and the track buttons")
    func skipSegmentPosition() {
        #expect(order(hasSkippableSegment: true) == [.restartButton, .skipSegmentButton, .audioButton, .subtitleButton, .speedButton, .pictureButton])
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

@Suite("Live transport focus order")
@MainActor
struct LiveTransportFocusOrderTests {
    private func order(isAtLiveEdge: Bool = true, hasAudioTracks: Bool = false,
                       hasSubtitles: Bool = false, isPiPAvailable: Bool = false,
                       showsStats: Bool = false) -> [PlayerViewModel.ControlsFocus] {
        PlayerViewModel.liveTransportFocusOrder(
            isAtLiveEdge: isAtLiveEdge, hasAudioTracks: hasAudioTracks,
            hasSubtitles: hasSubtitles, isPiPAvailable: isPiPAvailable,
            showsStats: showsStats)
    }

    @Test("a channel at the live edge with nothing to pick has no controls above the scrubber")
    func emptyAtEdge() {
        #expect(order().isEmpty)
    }

    @Test("Return to Live exists only while behind the edge, and leads")
    func returnToLiveGate() {
        #expect(order(isAtLiveEdge: false) == [.returnToLiveButton])
        #expect(order(isAtLiveEdge: false, hasAudioTracks: true).first == .returnToLiveButton)
        #expect(order(isAtLiveEdge: true, hasAudioTracks: true).contains(.returnToLiveButton) == false)
    }

    @Test("audio precedes subtitles, as in the VOD bar")
    func trackOrderMatchesVOD() {
        #expect(order(hasAudioTracks: true, hasSubtitles: true) == [.audioButton, .subtitleButton])
    }

    @Test("each control is gated on its own list, none on another's")
    func independentGates() {
        #expect(order(hasAudioTracks: true) == [.audioButton])
        #expect(order(hasSubtitles: true) == [.subtitleButton])
        #expect(order(isPiPAvailable: true) == [.pipButton])
    }

    @Test("PiP stays last so the track pickers keep their place as a channel gains tracks")
    func pipTrails() {
        #expect(order(isAtLiveEdge: false, hasAudioTracks: true, hasSubtitles: true, isPiPAvailable: true)
                == [.returnToLiveButton, .audioButton, .subtitleButton, .pipButton])
    }

    /// The live bar had no info chip at all, so the stats panel was unreachable on tvOS for the one kind of
    /// session whose route and tuner it is worth reading. It sits last, as in the VOD order.
    @Test("the stats chip follows the preference, and trails")
    func statsChipGate() {
        #expect(order(showsStats: true) == [.infoButton])
        #expect(order().contains(.infoButton) == false)
        #expect(order(isAtLiveEdge: false, hasAudioTracks: true, hasSubtitles: true,
                      isPiPAvailable: true, showsStats: true)
                == [.returnToLiveButton, .audioButton, .subtitleButton, .pipButton, .infoButton])
    }
}
