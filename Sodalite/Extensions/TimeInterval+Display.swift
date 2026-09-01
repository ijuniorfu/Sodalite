import Foundation

extension Int64 {
    /// Convert Jellyfin ticks (100ns units) to a display string like "1h 42m"
    var ticksToDisplay: String {
        let totalSeconds = self / 10_000_000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            let h = String(localized: "duration.hours.short", defaultValue: "h")
            let m = String(localized: "duration.minutes.short", defaultValue: "m")
            return "\(hours)\(h) \(minutes)\(m)"
        }
        let m = String(localized: "duration.minutes.short", defaultValue: "m")
        return "\(minutes)\(m)"
    }

    /// Compact form for the resume capsule's label, e.g. "23m" / "1h 48m" (en), "23min" /
    /// "1h 48min" (de). CLDR's narrow units, not `ticksToDisplay`'s own suffixes: measured across
    /// all 26 catalogue locales at the label sizes this is drawn at, our "Std."/"Min." spelling puts
    /// German at 69.9pt against narrow's 51.1pt and Polish at 74.5 against 51.1, which is the
    /// difference between a label that fits beside the meter on a phone poster and one that gets
    /// dropped (Sodalite#99). It also handles the edges by itself: an exact hour is "1h" rather than
    /// "1h 0m", and anything under a minute rounds up to "1m" rather than showing "0m".
    ///
    /// `ticksToDisplay` keeps its own spelling for the metadata rows, where the line has room and
    /// the longer form reads better.
    var ticksToCompactDisplay: String {
        Duration.seconds(ticksToSeconds)
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    /// Convert Jellyfin ticks to TimeInterval (seconds)
    var ticksToSeconds: TimeInterval {
        TimeInterval(self) / 10_000_000
    }
}
