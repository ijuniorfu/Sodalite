import Foundation

/// Formats a seconds value as `m:ss` (or `h:mm:ss`) for the music player and
/// now-playing card. Shared so the player bar and the mini card stay in sync.
enum MusicTimeFormatter {
    static func string(_ seconds: Double) -> String {
        guard seconds > 0 && seconds.isFinite else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
