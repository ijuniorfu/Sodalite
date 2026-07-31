import Foundation

protocol MediaDeletionServiceProtocol: Sendable {
    /// `cascadeToArrStack` also removes the Radarr entry via Seerr and clears any still-open request (no-op if Seerr has no record).
    func deleteMovie(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws

    /// Jellyfin cascades all seasons/episodes server-side; `cascadeToArrStack` also removes the Sonarr entry via Seerr and clears any still-open request.
    func deleteSeries(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws

    /// `cascadeToArrStack` accepted but IGNORED: Jellyseerr media-delete only operates per-series, so a season cascade would remove the whole Sonarr series. Param kept for signature symmetry.
    func deleteSeasons(seasonItemIDs: [String], cascadeToArrStack: Bool) async throws
}

@MainActor
final class MediaDeletionService: MediaDeletionServiceProtocol {
    private let jellyfinItems: any JellyfinItemServiceProtocol
    private let seerrMedia: any SeerrMediaServiceProtocol
    private let seerrRequests: any SeerrRequestServiceProtocol
    /// Active-Seerr-session check; a closure (not a SeerrClient injection) so it stays decoupled and re-reads live each call instead of caching a stale boolean. DependencyContainer wires it to `seerrClient.sessionCookie != nil`.
    private let isSeerrAuthenticated: @MainActor () -> Bool

    init(
        jellyfinItems: any JellyfinItemServiceProtocol,
        seerrMedia: any SeerrMediaServiceProtocol,
        seerrRequests: any SeerrRequestServiceProtocol,
        isSeerrAuthenticated: @escaping @MainActor () -> Bool
    ) {
        self.jellyfinItems = jellyfinItems
        self.seerrMedia = seerrMedia
        self.seerrRequests = seerrRequests
        self.isSeerrAuthenticated = isSeerrAuthenticated
    }

    func deleteMovie(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws {
        try await cascadeDelete(itemID: itemID, tmdbID: tmdbID, cascadeToArrStack: cascadeToArrStack) { id in
            _ = try await self.seerrMedia.removeMovieFromRadarr(tmdbID: id)
            let info = try? await self.seerrMedia.movieDetail(tmdbID: id).mediaInfo
            await self.deleteOpenRequests(in: info)
        }
    }

    func deleteSeries(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws {
        try await cascadeDelete(itemID: itemID, tmdbID: tmdbID, cascadeToArrStack: cascadeToArrStack) { id in
            _ = try await self.seerrMedia.removeSeriesFromSonarr(tmdbID: id)
            let info = try? await self.seerrMedia.tvDetail(tmdbID: id).mediaInfo
            await self.deleteOpenRequests(in: info)
        }
    }

    /// Removing the title from Radarr/Sonarr leaves its request untouched, and Jellyseerr's availability
    /// sync only ever revisits available titles, so that request keeps reporting a pipeline state for a
    /// title that no longer exists, forever. Clearing it here is what keeps the two sides consistent.
    /// Best-effort by design: the deletion itself has already succeeded, and a request the current user
    /// may not delete (Jellyseerr answers 403) must not turn a completed deletion into a failure.
    private func deleteOpenRequests(in info: SeerrMediaInfo?) async {
        for request in info?.requests ?? [] where request.isOpen {
            try? await seerrRequests.deleteRequest(requestID: request.id)
        }
    }

    /// Delete the Jellyfin item, then optionally cascade the *arr-stack removal through Seerr.
    /// `seerrOperation` receives the unwrapped tmdbID and performs the Radarr/Sonarr removal.
    private func cascadeDelete(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool, seerrOperation: (Int) async throws -> Void) async throws {
        do {
            try await jellyfinItems.deleteItem(itemID: itemID)
        } catch {
            throw MediaDeletionError(stage: .jellyfin)
        }
        guard cascadeToArrStack, let tmdbID = tmdbID else { return }
        // Cascade needs an active Seerr session (MANAGE_REQUESTS); surface the missing-session case as a typed reason.
        guard isSeerrAuthenticated() else {
            throw MediaDeletionError(stage: .seerr, reason: .seerrNotSignedIn)
        }
        do {
            try await seerrOperation(tmdbID)
        } catch {
            throw MediaDeletionError(stage: .seerr)
        }
    }

    func deleteSeasons(seasonItemIDs: [String], cascadeToArrStack: Bool) async throws {
        // cascadeToArrStack ignored: Jellyseerr media-delete is series-granular, refuse to silently remove the whole Sonarr series.
        for itemID in seasonItemIDs {
            do {
                try await jellyfinItems.deleteItem(itemID: itemID)
            } catch {
                throw MediaDeletionError(stage: .jellyfin)
            }
        }
    }
}
