import Foundation

extension PlayerViewModel {
    /// Left-to-right order of the VOD transport buttons. Built from the same gates TransportBar
    /// renders with: the two must agree, else left/right focus lands on an unrendered button.
    /// Live has its own two-button row (LiveTransportBar) and does not use this.
    static func transportFocusOrder(
        isInsideIntro: Bool,
        episodeCount: Int,
        chapterCount: Int,
        hasAudioTracks: Bool,
        hasSubtitles: Bool,
        isPiPAvailable: Bool,
        showsStats: Bool
    ) -> [ControlsFocus] {
        var order: [ControlsFocus] = [.restartButton]
        if isInsideIntro { order.append(.skipIntroButton) }
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
}
