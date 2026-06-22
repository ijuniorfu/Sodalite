import Foundation

/// Media-deletion failure. `stage` distinguishes Jellyfin failure (item never deleted) from Seerr-cascade failure after Jellyfin succeeded (file gone, *arr-stack entry orphaned) so the UI can say retry vs expect-orphan. `reason` adds the "not signed into Seerr" case (cascade enabled with no Seerr session) for an honest toast instead of generic API error.
struct MediaDeletionError: Error, Sendable {
    enum Stage: Sendable { case jellyfin, seerr }
    enum Reason: Sendable {
        case generic
        case seerrNotSignedIn
    }
    let stage: Stage
    let reason: Reason
    let underlying: Error?
    /// True when Jellyfin succeeded but Seerr failed afterwards. The
    /// caller surfaces a different toast in that case.
    var partialSuccess: Bool { stage == .seerr }

    init(stage: Stage, reason: Reason = .generic, underlying: Error? = nil) {
        self.stage = stage
        self.reason = reason
        self.underlying = underlying
    }
}
