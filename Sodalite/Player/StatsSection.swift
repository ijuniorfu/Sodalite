import Foundation

/// Indices into `PlayerViewModel.statsSectionAnchors`, named so a caller never counts them out by hand.
enum StatsSection {
    static let live = 0
    static let playback = 1
    static let video = 2
    static let audio = 3
    static let subtitle = 4
    /// File for a VOD session, channel for a live one: a tuner has no file, and the two never coexist.
    static let source = 5
    static let engine = 6
    static let buffer = 7
    static let network = 8

    /// Which sections have something to say. The panel renders from this and the Up/Down cursor pages
    /// through it, so a section can never be reachable without being drawn or drawn without being
    /// reachable. Those were two lists in two files before, and the file-section gate had already drifted:
    /// the cursor asked `item.mediaSources`, the panel asked the resolved source.
    ///
    /// Live and Playback are unconditional. Live telemetry is nil before the first sample, and a section
    /// that appears a second into playback would move every anchor under a cursor already in it.
    static func available(
        hasVideo: Bool,
        hasAudio: Bool,
        hasSubtitle: Bool,
        hasSourceDetail: Bool,
        showEngineDiagnostics: Bool
    ) -> Set<Int> {
        var indices: Set<Int> = [live, playback]
        if hasVideo { indices.insert(video) }
        if hasAudio { indices.insert(audio) }
        if hasSubtitle { indices.insert(subtitle) }
        if hasSourceDetail { indices.insert(source) }
        if showEngineDiagnostics {
            indices.formUnion([engine, buffer, network])
        }
        return indices
    }
}
