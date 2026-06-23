import Foundation

protocol MediaDeletionServiceProtocol: Sendable {
    /// `cascadeToArrStack` also removes the Radarr entry via Seerr (no-op if Seerr has no record).
    func deleteMovie(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws

    /// Jellyfin cascades all seasons/episodes server-side; `cascadeToArrStack` also removes the Sonarr entry via Seerr.
    func deleteSeries(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws

    /// `cascadeToArrStack` accepted but IGNORED: Jellyseerr media-delete only operates per-series, so a season cascade would remove the whole Sonarr series. Param kept for signature symmetry.
    func deleteSeasons(seasonItemIDs: [String], cascadeToArrStack: Bool) async throws
}

@MainActor
final class MediaDeletionService: MediaDeletionServiceProtocol {
    private let jellyfinItems: any JellyfinItemServiceProtocol
    private let seerrMedia: any SeerrMediaServiceProtocol
    /// Active-Seerr-session check; a closure (not a SeerrClient injection) so it stays decoupled and re-reads live each call instead of caching a stale boolean. DependencyContainer wires it to `seerrClient.sessionCookie != nil`.
    private let isSeerrAuthenticated: @MainActor () -> Bool

    init(
        jellyfinItems: any JellyfinItemServiceProtocol,
        seerrMedia: any SeerrMediaServiceProtocol,
        isSeerrAuthenticated: @escaping @MainActor () -> Bool
    ) {
        self.jellyfinItems = jellyfinItems
        self.seerrMedia = seerrMedia
        self.isSeerrAuthenticated = isSeerrAuthenticated
    }

    func deleteMovie(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws {
        try await cascadeDelete(itemID: itemID, tmdbID: tmdbID, cascadeToArrStack: cascadeToArrStack) { id in
            _ = try await self.seerrMedia.removeMovieFromRadarr(tmdbID: id)
        }
    }

    func deleteSeries(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws {
        try await cascadeDelete(itemID: itemID, tmdbID: tmdbID, cascadeToArrStack: cascadeToArrStack) { id in
            _ = try await self.seerrMedia.removeSeriesFromSonarr(tmdbID: id)
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
