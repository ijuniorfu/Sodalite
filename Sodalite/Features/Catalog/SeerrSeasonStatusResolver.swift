import Foundation

/// Resolves the per-season pipeline status Jellyseerr reports for a series, layering the authoritative
/// Sonarr-scan status over the in-flight request states. Pure so the axis mapping is unit-testable.
enum SeerrSeasonStatusResolver {
    /// (1) `mediaInfo.seasons`, authoritative Sonarr-scan status, the sole source of genuine availability.
    /// (2) `mediaInfo.requests[].seasons[]` for in-flight pipeline states (processing, pending approval) only from still-active requests.
    static func status(seasonNumber n: Int, mediaInfo: SeerrMediaInfo?) -> SeerrMediaStatus? {
        // 1. Authoritative: server-derived per-season status.
        if let mediaSeasons = mediaInfo?.seasons {
            for s in mediaSeasons where s.seasonNumber == n {
                switch s.status {
                case .available: return .available
                case .partiallyAvailable: return .partiallyAvailable
                case .processing: return .processing
                case .pending: return .pending
                case .deleted: return .deleted
                case .unknown, .none: break
                }
            }
        }

        // 2. Fallback: in-flight states from still-active requests only. Jellyseerr never reverts request.seasons[].status, so a declined/failed/completed request keeps stale entries; gating on request.status is required or a cancelled season stays pinned forever (overseerr#690). Availability is owned solely by path #1, so the request walk never surfaces .available.
        guard let requests = mediaInfo?.requests else { return nil }
        var hasProcessing = false
        var hasPending = false
        for request in requests where request.status == .pendingApproval || request.status == .approved {
            guard let seasons = request.seasons else { continue }
            // Request axis -> display axis. An approved season is already on its way to Sonarr, so it reads as processing; only an undecided one waits for approval. Completed seasons say nothing here, path #1 owns availability.
            for s in seasons where s.seasonNumber == n {
                switch s.status {
                case .approved: hasProcessing = true
                case .pendingApproval: hasPending = true
                case .declined, .failed, .completed, .none: break
                }
            }
        }
        if hasProcessing { return .processing }
        if hasPending { return .pending }
        return nil
    }
}
