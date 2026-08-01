import Foundation

/// SPIKE, delete before merge (feat/topshelf-progress-bar).
///
/// The extension's `os.Logger` output is unreachable from here: tvOS null-redirects stdout with no
/// debugger attached, and `log collect` wants root. Preferences in the group container *are*
/// writable (proven by the app's accent mirror landing there), so the run record goes through
/// UserDefaults and comes back off the device with `devicectl device copy from`.
enum TopShelfDiagnostics {
    private static let runCountKey = "topshelf.diag.runCount"
    private static let lastRunKey = "topshelf.diag.lastRun"
    private static let lastNoteKey = "topshelf.diag.lastNote"

    static func record(_ note: String) {
        guard let defaults = UserDefaults(suiteName: TopShelfCachePolicy.appGroup) else { return }
        let count = defaults.integer(forKey: runCountKey) + 1
        defaults.set(count, forKey: runCountKey)
        defaults.set(ISO8601DateFormatter().string(from: Date()), forKey: lastRunKey)
        defaults.set(note, forKey: lastNoteKey)
    }
}
