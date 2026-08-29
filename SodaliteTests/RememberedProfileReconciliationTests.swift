import Foundation
import Testing
@testable import Sodalite

/// Sodalite#90. A profile deleted on the server kept its card in every picker forever, so the list
/// has to be held against the server's own user table. The removal is a tombstone that travels to
/// every synced device, so the policy withholds a verdict wherever the answer is not one to act on.
@Suite("Remembered profiles reconciled against the server's user table")
struct RememberedProfileReconciliationTests {
    private func remembered(_ ids: String...) -> [RememberedUser] {
        ids.map {
            RememberedUser(id: $0, serverID: "srv1", name: "Name \($0)", imageTag: nil, token: "t-\($0)")
        }
    }

    private func stale(
        _ users: [RememberedUser],
        server: [String],
        active: String? = "user-a"
    ) -> [String] {
        RememberedProfileReconciliation.staleProfileIDs(
            remembered: users,
            serverUserIDs: server,
            activeUserID: active
        )
    }

    @Test func aProfileTheServerNoLongerHasIsDropped() {
        #expect(stale(remembered("user-a", "user-b"), server: ["user-a"]) == ["user-b"])
    }

    @Test func profilesTheServerStillHasAreKept() {
        #expect(stale(remembered("user-a", "user-b"), server: ["user-a", "user-b"]).isEmpty)
    }

    /// A user listing that does not carry the session's own user is not describing the table this
    /// session lives in (a proxy, a different server behind the same URL), so it cannot speak for
    /// the profiles beside it either.
    @Test func aListingWithoutTheActiveUserDecidesNothing() {
        #expect(stale(remembered("user-a", "user-b"), server: ["user-x", "user-y"]).isEmpty)
    }

    /// An empty answer is a response about something other than a running Jellyfin, never a
    /// household that deleted everyone.
    @Test func anEmptyListingDecidesNothing() {
        #expect(stale(remembered("user-a", "user-b"), server: []).isEmpty)
    }

    /// Without a session pointer there is nothing to cross-check the listing against, but the
    /// listing itself is still the server's own answer.
    @Test func withoutAnActiveUserTheListingStillCounts() {
        #expect(stale(remembered("user-a", "user-b"), server: ["user-a"], active: nil) == ["user-b"])
    }

    /// Jellyfin hands out the same GUID dashed and dashless depending on which response it came
    /// from; a stored copy in the other form must not read as a deleted user.
    @Test func guidFormattingDoesNotDecideExistence() {
        let dashed = RememberedUser(
            id: "0F3A9C4E-1B2D-4E5F-8A9B-0C1D2E3F4A5B",
            serverID: "srv1", name: "Vincent", imageTag: nil, token: "t"
        )
        let ids = RememberedProfileReconciliation.staleProfileIDs(
            remembered: [dashed],
            serverUserIDs: ["0f3a9c4e1b2d4e5f8a9b0c1d2e3f4a5b"],
            activeUserID: "0f3a9c4e1b2d4e5f8a9b0c1d2e3f4a5b"
        )
        #expect(ids.isEmpty)
    }

    /// The ids come back in the form the local store knows them by, because that is what the
    /// keychain entry, the tombstone and the credential purge are keyed on.
    @Test func droppedIDsComeBackInTheLocalForm() {
        let dashed = RememberedUser(
            id: "0F3A9C4E-1B2D-4E5F-8A9B-0C1D2E3F4A5B",
            serverID: "srv1", name: "Guest", imageTag: nil, token: "t"
        )
        let ids = RememberedProfileReconciliation.staleProfileIDs(
            remembered: [dashed],
            serverUserIDs: ["aaaa"],
            activeUserID: "aaaa"
        )
        #expect(ids == ["0F3A9C4E-1B2D-4E5F-8A9B-0C1D2E3F4A5B"])
    }
}
