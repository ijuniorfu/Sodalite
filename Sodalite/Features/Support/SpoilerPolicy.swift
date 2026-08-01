import Foundation

/// Sodalite#50. Decides whether an item's synopsis and still are veiled. A pure value so the
/// whole matrix is unit-testable; the environment reads live in `spoilerVeil`.
struct SpoilerPolicy: Sendable, Equatable {
    var enabled: Bool
    var hideEpisodes: Bool
    var hideMovies: Bool
    var userID: String
    /// Shared with `SpoilerRevealMemory` by COW, so building a policy per card body is a retain, not a copy.
    var revealedKeys: Set<String>

    /// What is being covered. Not every veiled item veils both.
    enum Surface: Sendable {
        /// Descriptions and synopses.
        case text
        /// Stills, posters, backdrops.
        case artwork
    }

    static let disabled = SpoilerPolicy(
        enabled: false,
        hideEpisodes: false,
        hideMovies: false,
        userID: "",
        revealedKeys: []
    )

    /// Per item, deliberately unlike `TrackSelectionMemory.scopeKey`, which folds episodes under
    /// their series: revealing one episode must not reveal the whole season.
    static func key(userID: String, itemID: String) -> String {
        "\(userID)|\(itemID)"
    }

    func key(for item: JellyfinItem) -> String {
        Self.key(userID: userID, itemID: item.id)
    }

    /// Artwork is only a spoiler on an episode, where the still is a frame out of that very
    /// episode. A movie poster is marketing art the viewer has already seen everywhere, so
    /// blurring it hides which movie this is rather than what happens in it. A season poster is
    /// the same marketing art, so a season veils its synopsis only.
    func isHidden(_ item: JellyfinItem, surface: Surface) -> Bool {
        guard isHidden(item) else { return false }
        switch surface {
        case .text: return true
        case .artwork: return item.type == .episode
        }
    }

    /// The base decision, before any surface narrows it further.
    func isHidden(_ item: JellyfinItem) -> Bool {
        guard enabled else { return false }
        switch item.type {
        // A season synopsis describes that season's arc, so it is the same class of spoiler as an
        // episode synopsis and rides the same switch.
        case .episode where hideEpisodes: break
        case .season where hideEpisodes: break
        case .movie where hideMovies: break
        default: return false
        }
        if item.userData?.played == true { return false }
        // Started counts as revealed: every Continue Watching entry is in progress, so without
        // this the one row users look at most would be a wall of blur.
        if (item.userData?.playedPercentage ?? 0) > 0 { return false }
        if hasWatchedChild(item) { return false }
        return !revealedKeys.contains(key(for: item))
    }

    /// Same "started reveals" intent one level up: a season carries no played percentage (Jellyfin
    /// computes that for playable items), so a started season is one with at least one episode
    /// watched. Needs both counts, and a caller that skipped ChildCount gets no reveal rather than
    /// a wrong one.
    private func hasWatchedChild(_ item: JellyfinItem) -> Bool {
        guard let total = item.childCount, let unplayed = item.userData?.unplayedItemCount else {
            return false
        }
        return unplayed < total
    }
}
