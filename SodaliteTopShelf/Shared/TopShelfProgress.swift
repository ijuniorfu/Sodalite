import Foundation

/// Resume fraction for a Top Shelf cell. Its own file because the extension, both app targets,
/// and the tests all compile it; `nonisolated` because the app targets default to MainActor
/// isolation and the extension defaults to nonisolated, and the members have to agree.
enum TopShelfProgress {
    /// nil means "leave playbackProgress unset". Writing 0 draws an empty bar under every
    /// Next Up cell, which reads as "started and abandoned" for something never opened.
    nonisolated static func fraction(playedPercentage: Double?,
                                     positionTicks: Int64?,
                                     runTimeTicks: Int64?) -> Double? {
        if let playedPercentage {
            return clamped(playedPercentage / 100)
        }
        guard let positionTicks, let runTimeTicks, runTimeTicks > 0 else { return nil }
        return clamped(Double(positionTicks) / Double(runTimeTicks))
    }

    nonisolated private static func clamped(_ value: Double) -> Double? {
        guard value.isFinite, value > 0 else { return nil }
        return min(value, 1)
    }
}
