import Foundation

protocol MediaDeletionServiceProtocol: Sendable {
    /// Deletes a movie from Jellyfin. If `cascadeToArrStack` is true,
    /// also instructs Seerr to remove the Radarr entry (no-op if Seerr
    /// has no record for the title).
    func deleteMovie(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws

    /// Deletes an entire series from Jellyfin (cascades to all seasons
    /// + episodes server-side). If `cascadeToArrStack` is true, also
    /// instructs Seerr to remove the Sonarr entry.
    func deleteSeries(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws

    /// Deletes one or more seasons from Jellyfin. The Seerr cascade is
    /// not available at season granularity (Jellyseerr's media-delete
    /// endpoint only operates on the whole series), so
    /// `cascadeToArrStack` is accepted but ignored. The UI prevents the
    /// toggle from being on in this case; the parameter is here for
    /// signature symmetry.
    func deleteSeasons(seasonItemIDs: [String], cascadeToArrStack: Bool) async throws
}

@MainActor
final class MediaDeletionService: MediaDeletionServiceProtocol {
    private let jellyfinItems: any JellyfinItemServiceProtocol
    private let seerrMedia: any SeerrMediaServiceProtocol
    /// Returns true when the host currently has an active Seerr session
    /// cookie. Read each call so the result reacts live to session
    /// expiry / sign-out without the service caching a stale boolean.
    /// Implemented as a closure (rather than a SeerrClient injection)
    /// so the service stays decoupled from the client; the
    /// DependencyContainer wires it to `seerrClient.sessionCookie != nil`.
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
        do {
            try await jellyfinItems.deleteItem(itemID: itemID)
        } catch {
            throw MediaDeletionError(stage: .jellyfin, underlying: error)
        }
        guard cascadeToArrStack, let tmdbID = tmdbID else { return }
        // Pre-flight: the cascade call requires an active Seerr session
        // (MANAGE_REQUESTS permission on the Seerr user). Surface the
        // missing-session case as a typed reason so the UI can render
        // a specific toast instead of the generic "could not remove".
        guard isSeerrAuthenticated() else {
            throw MediaDeletionError(stage: .seerr, reason: .seerrNotSignedIn)
        }
        do {
            _ = try await seerrMedia.removeMovieFromRadarr(tmdbID: tmdbID)
        } catch {
            throw MediaDeletionError(stage: .seerr, underlying: error)
        }
    }

    func deleteSeries(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws {
        do {
            try await jellyfinItems.deleteItem(itemID: itemID)
        } catch {
            throw MediaDeletionError(stage: .jellyfin, underlying: error)
        }
        guard cascadeToArrStack, let tmdbID = tmdbID else { return }
        guard isSeerrAuthenticated() else {
            throw MediaDeletionError(stage: .seerr, reason: .seerrNotSignedIn)
        }
        do {
            _ = try await seerrMedia.removeSeriesFromSonarr(tmdbID: tmdbID)
        } catch {
            throw MediaDeletionError(stage: .seerr, underlying: error)
        }
    }

    func deleteSeasons(seasonItemIDs: [String], cascadeToArrStack: Bool) async throws {
        // cascadeToArrStack is intentionally ignored. Jellyseerr's
        // media-delete endpoint only operates at series granularity; if
        // the caller asked for a season-cascade the UI is buggy, but we
        // refuse to silently remove the whole Sonarr series.
        for itemID in seasonItemIDs {
            do {
                try await jellyfinItems.deleteItem(itemID: itemID)
            } catch {
                throw MediaDeletionError(stage: .jellyfin, underlying: error)
            }
        }
    }
}
