import Testing
@testable import Sodalite

/// Audit 2026-09-25 BROWSE-6. A NavigationStack push/pop through a provider grid's own
/// navigationDestination re-fires `.task(id: reloadKey)` with an unchanged key, and the grid used to
/// treat that exactly like a real reload: the 10 000-item scan (the app's biggest request,
/// Sodalite#68) and the ~10 Seerr watch-provider calls behind it ran again on every back-out. This
/// pins the reuse policy `loadItems()` now guards the scan and the Seerr augment with.
struct FilteredGridPhase2CacheTests {

    @Test("a plain grid (no smart provider) never reuses a phase 2 cache")
    func plainGridNeverReuses() {
        #expect(
            FilteredGridView.canReuseCachedPhase2(
                smartProviderID: nil, cacheFilter: .all, currentFilter: .all
            ) == false
        )
    }

    @Test("no resolve has landed yet, so there is nothing to reuse")
    func noCacheYetDoesNotReuse() {
        #expect(
            FilteredGridView.canReuseCachedPhase2(
                smartProviderID: 8, cacheFilter: nil, currentFilter: .all
            ) == false
        )
    }

    @Test("a reappear under the same watch filter reuses the cached resolve")
    func reappearWithSameFilterReuses() {
        #expect(
            FilteredGridView.canReuseCachedPhase2(
                smartProviderID: 8, cacheFilter: .unwatched, currentFilter: .unwatched
            ) == true
        )
    }

    /// The filter narrows both phases server-side (studio query AND the 10k scan), so a resolve
    /// cached under one filter must never stand in for another.
    @Test("switching the watch filter invalidates the cache")
    func filterChangeDoesNotReuse() {
        #expect(
            FilteredGridView.canReuseCachedPhase2(
                smartProviderID: 8, cacheFilter: .all, currentFilter: .unwatched
            ) == false
        )
    }
}
