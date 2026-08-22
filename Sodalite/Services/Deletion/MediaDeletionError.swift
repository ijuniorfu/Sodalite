import Foundation

/// Media-deletion failure. `stage` distinguishes Jellyfin failure (item never deleted) from Seerr-cascade failure after Jellyfin succeeded (file gone, *arr-stack entry orphaned) so the UI can say retry vs expect-orphan. `reason` adds the "not signed into Seerr" case (cascade enabled with no Seerr session) for an honest toast instead of generic API error.
struct MediaDeletionError: LocalizedError, Sendable {
    enum Stage: Sendable { case jellyfin, seerr }
    enum Reason: Sendable {
        case generic
        case seerrNotSignedIn
    }
    let stage: Stage
    let reason: Reason
    /// True when Jellyfin succeeded but Seerr failed afterwards. The
    /// caller surfaces a different toast in that case.
    var partialSuccess: Bool { stage == .seerr }

    init(stage: Stage, reason: Reason = .generic) {
        self.stage = stage
        self.reason = reason
    }

    /// The deletion sheet reads `stage` and `reason` directly, because the toast's KIND (partial vs
    /// failed) is a decision, not a sentence. This exists so the type can still describe itself where
    /// something only has an `Error` in hand, and it reuses that sheet's copy rather than inventing a
    /// second wording for the same event.
    var errorDescription: String? {
        if reason == .seerrNotSignedIn {
            return String(localized: "delete.toast.seerrNotSignedIn")
        }
        return partialSuccess
            ? String(localized: "delete.toast.partialSuccess")
            : String(localized: "delete.toast.failure")
    }
}
