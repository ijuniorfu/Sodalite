#if os(tvOS)
import TVServices
#endif

/// Tells tvOS the Top Shelf's backing data changed, so it re-asks the extension instead of
/// serving its last snapshot until its own refresh cycle comes around. No-op off tvOS: the
/// iOS target compiles the same sources and has no shelf.
enum TopShelfRefresher {
    /// Cheap and idempotent, so call sites fire it unconditionally rather than diffing against
    /// what the shelf currently shows.
    nonisolated static func invalidate() {
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }
}
