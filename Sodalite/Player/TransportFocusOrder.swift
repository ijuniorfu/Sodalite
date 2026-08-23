import Foundation

extension PlayerViewModel {
    /// Left-to-right order of the VOD transport buttons. Built from the same gates TransportBar
    /// renders with: the two must agree, else left/right focus lands on an unrendered button.
    /// Live has its own two-button row (LiveTransportBar) and does not use this.
    static func transportFocusOrder(
        hasSkippableSegment: Bool,
        episodeCount: Int,
        chapterCount: Int,
        hasAudioTracks: Bool,
        hasSubtitles: Bool,
        isPiPAvailable: Bool,
        showsStats: Bool
    ) -> [ControlsFocus] {
        var order: [ControlsFocus] = [.restartButton]
        if hasSkippableSegment { order.append(.skipSegmentButton) }
        if episodeCount > 1 { order.append(.episodeButton) }
        if chapterCount > 1, episodeCount <= 1 { order.append(.chapterButton) }
        if hasAudioTracks { order.append(.audioButton) }
        if hasSubtitles { order.append(.subtitleButton) }
        order.append(.speedButton)
        order.append(.pictureButton)
        if isPiPAvailable { order.append(.pipButton) }
        if showsStats { order.append(.infoButton) }
        return order
    }

    /// Left-to-right order of the LIVE transport controls (LiveTransportBar). Same contract as the
    /// VOD order above: the bar renders from these gates, so a button missing here is a dead stop
    /// under left/right, and a button missing there is focus on nothing. Track order follows the VOD
    /// bar (audio, then subtitles) so both players read the same way.
    static func liveTransportFocusOrder(
        isAtLiveEdge: Bool,
        hasAudioTracks: Bool,
        hasSubtitles: Bool,
        isPiPAvailable: Bool,
        showsStats: Bool
    ) -> [ControlsFocus] {
        var order: [ControlsFocus] = []
        // Return to Live exists only while behind the edge; at the edge there is nothing to return to.
        if !isAtLiveEdge { order.append(.returnToLiveButton) }
        if hasAudioTracks { order.append(.audioButton) }
        if hasSubtitles { order.append(.subtitleButton) }
        if isPiPAvailable { order.append(.pipButton) }
        if showsStats { order.append(.infoButton) }
        return order
    }

    /// The live order for the current session, gated exactly as LiveTransportBar renders.
    var liveTransportFocusOrder: [ControlsFocus] {
        Self.liveTransportFocusOrder(
            isAtLiveEdge: isAtLiveEdge,
            hasAudioTracks: !displayAudioTracks.isEmpty,
            hasSubtitles: !displaySubtitleStreams.isEmpty,
            isPiPAvailable: isPiPAvailable,
            showsStats: preferences.showStatsForNerds)
    }
}
