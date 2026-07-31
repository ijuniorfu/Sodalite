import Testing
import Foundation
@testable import Sodalite

/// Jellyseerr serves two status axes with colliding integers: `Season.status` is a MediaStatus
/// (1 unknown, 2 pending, 3 processing, 4 partial, 5 available) while `SeasonRequest.status` is a
/// MediaRequestStatus (1 pending approval, 2 approved, 3 declined, 4 failed, 5 completed). The
/// fixtures below are raw wire payloads so the axis mapping stays pinned.
@MainActor
struct SeerrSeasonStatusResolverTests {
    private func mediaInfo(_ json: String) throws -> SeerrMediaInfo {
        try JSONDecoder().decode(SeerrMediaInfo.self, from: Data(json.utf8))
    }

    /// Admin (auto-approve) request: the season request lands on APPROVED, which must not read as "waiting for approval".
    @Test func autoApprovedSeasonRequestReadsAsProcessing() throws {
        let info = try mediaInfo("""
        {"id": 1, "tmdbId": 42, "status": 3, "seasons": [],
         "requests": [{"id": 7, "status": 2, "type": "tv",
                       "seasons": [{"id": 11, "seasonNumber": 1, "status": 2}]}]}
        """)
        #expect(SeerrSeasonStatusResolver.status(seasonNumber: 1, mediaInfo: info) == .processing)
    }

    /// Non-admin request awaiting an approval decision: MediaRequestStatus.PENDING is 1, not 2.
    @Test func pendingSeasonRequestReadsAsPendingApproval() throws {
        let info = try mediaInfo("""
        {"id": 1, "tmdbId": 42, "status": 2, "seasons": [],
         "requests": [{"id": 7, "status": 1, "type": "tv",
                       "seasons": [{"id": 11, "seasonNumber": 1, "status": 1}]}]}
        """)
        #expect(SeerrSeasonStatusResolver.status(seasonNumber: 1, mediaInfo: info) == .pending)
    }

    /// DECLINED is 3 on the request axis; it must not be read as MediaStatus.PROCESSING.
    @Test func declinedRequestContributesNoStatus() throws {
        let info = try mediaInfo("""
        {"id": 1, "tmdbId": 42, "status": 1, "seasons": [],
         "requests": [{"id": 7, "status": 3, "type": "tv",
                       "seasons": [{"id": 11, "seasonNumber": 1, "status": 3}]}]}
        """)
        #expect(SeerrSeasonStatusResolver.status(seasonNumber: 1, mediaInfo: info) == nil)
    }

    /// COMPLETED (5) on a season request must not claim availability; path #1 owns that.
    @Test func completedSeasonRequestDoesNotClaimAvailability() throws {
        let info = try mediaInfo("""
        {"id": 1, "tmdbId": 42, "status": 3, "seasons": [],
         "requests": [{"id": 7, "status": 2, "type": "tv",
                       "seasons": [{"id": 11, "seasonNumber": 1, "status": 5}]}]}
        """)
        #expect(SeerrSeasonStatusResolver.status(seasonNumber: 1, mediaInfo: info) == nil)
    }

    /// Jellyseerr's own media-file delete (DELETE /media/:id/file, what Sodalite's delete flow calls) stamps every season DELETED but leaves the approved request untouched. The delete must win over that stale request.
    @Test func deletedSeasonWinsOverStaleApprovedRequest() throws {
        let info = try mediaInfo("""
        {"id": 1, "tmdbId": 42, "status": 7,
         "seasons": [{"id": 3, "seasonNumber": 1, "status": 7, "status4k": 1}],
         "requests": [{"id": 7, "status": 2, "type": "tv",
                       "seasons": [{"id": 11, "seasonNumber": 1, "status": 2}]}]}
        """)
        #expect(SeerrSeasonStatusResolver.status(seasonNumber: 1, mediaInfo: info) == .deleted)
    }

    /// Sonarr-scan status wins over the in-flight request state.
    @Test func mediaSeasonStatusWinsOverRequest() throws {
        let info = try mediaInfo("""
        {"id": 1, "tmdbId": 42, "status": 5,
         "seasons": [{"id": 3, "seasonNumber": 1, "status": 5, "status4k": 1}],
         "requests": [{"id": 7, "status": 2, "type": "tv",
                       "seasons": [{"id": 11, "seasonNumber": 1, "status": 2}]}]}
        """)
        #expect(SeerrSeasonStatusResolver.status(seasonNumber: 1, mediaInfo: info) == .available)
    }

    /// A season row Sonarr has not scanned yet (UNKNOWN) falls through to the request walk.
    @Test func unknownMediaSeasonFallsThroughToRequests() throws {
        let info = try mediaInfo("""
        {"id": 1, "tmdbId": 42, "status": 3,
         "seasons": [{"id": 3, "seasonNumber": 1, "status": 1, "status4k": 1}],
         "requests": [{"id": 7, "status": 2, "type": "tv",
                       "seasons": [{"id": 11, "seasonNumber": 1, "status": 2}]}]}
        """)
        #expect(SeerrSeasonStatusResolver.status(seasonNumber: 1, mediaInfo: info) == .processing)
    }

    @Test func untrackedSeasonHasNoStatus() throws {
        let info = try mediaInfo("""
        {"id": 1, "tmdbId": 42, "status": 3, "seasons": [],
         "requests": [{"id": 7, "status": 2, "type": "tv",
                       "seasons": [{"id": 11, "seasonNumber": 1, "status": 2}]}]}
        """)
        #expect(SeerrSeasonStatusResolver.status(seasonNumber: 2, mediaInfo: info) == nil)
    }

    @Test func noMediaInfoHasNoStatus() {
        #expect(SeerrSeasonStatusResolver.status(seasonNumber: 1, mediaInfo: nil) == nil)
    }
}
