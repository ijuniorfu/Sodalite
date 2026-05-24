# File Management from Sodalite

Date: 2026-05-24
Status: approved, ready for implementation plan
Tracking: Sub-project A of the "admin features" pair (B is Seerr request approval, separate spec)

## Motivation

Jellyfin servers grow. Movies finish their lifecycle, shows finish their seasons, old encodes get replaced by remuxes. Today, to delete anything from the server a user has to leave Sodalite, open the Jellyfin web UI, and find the item. The Radarr/Sonarr side is even more friction: open another tab, find the title, remove the entry, otherwise the *arr stack will dutifully re-download a copy of what you just deleted.

Goal: from inside Sodalite, an authorised user can delete a movie, an entire series, or one or more seasons. The same confirmation step optionally also removes the Radarr/Sonarr database entry so the *arr stack forgets the title, instead of re-monitoring it.

## Scope

In scope:

- Decode Jellyfin's `Policy` sub-object on `getCurrentUser()` so the app knows whether the logged-in user has the `EnableContentDeletion` flag set.
- New `MediaDeletionService` providing `deleteMovie`, `deleteSeries`, `deleteSeasons` methods, each accepting a `cascadeToArrStack: Bool` parameter.
- Delete buttons in `MovieDetailView` and `SeriesDetailView`, only rendered when the current user has the permission.
- A reusable confirmation sheet (`MediaDeletionSheet`) with one variant for the simple "delete this movie / delete this series" case and a season-multi-select variant for the series case.
- Localised in all 26 supported languages on first ship.

Out of scope:

- Episode-level deletion. Vincent's design call. Episode-level cleanup is a maintenance task that belongs in a "tidy up" tool, not in playback flow.
- Per-folder permission granularity (`Policy.EnableContentDeletionFromFolders`). The single `EnableContentDeletion` boolean is enough; per-folder gating is a Stretch goal if a user complains.
- Direct Radarr/Sonarr API access. Sodalite stays Jellyfin + Seerr only; Seerr proxies to the *arr stack.
- A confirmation step on the Jellyfin server itself. Jellyfin's `DELETE /Items/{id}` is destructive on a single call; we wrap it in a tvOS-friendly confirmation but don't add server-side "deletion request" plumbing.

## Architecture

```
Sodalite
├── Models/Jellyfin/JellyfinUser.swift           (modified: add Policy sub-struct)
├── Services/Deletion/
│   ├── MediaDeletionService.swift               (new: protocol + impl)
│   └── MediaDeletionViewModel.swift             (new: per-detail-view VM)
├── Features/Detail/
│   ├── MovieDetailView.swift                    (modified: add Delete button)
│   ├── SeriesDetailView.swift                   (modified: add Delete button)
│   └── UI/MediaDeletionSheet.swift              (new: confirmation sheet)
└── Services/Jellyfin/JellyfinItemService.swift  (modified: add deleteItem method)
└── Services/Seerr/SeerrMediaService.swift       (modified: add deleteMediaFile method)
```

`MediaDeletionService` is the single boundary the rest of the app talks to. Detail views never call Jellyfin or Seerr directly for deletion.

Permission state piggy-backs on the existing `AppState.activeUser: JellyfinUser?` (already `@Observable`-published, already replaced atomically on profile switch / login / logout). Adding `policy` as a sub-field on `JellyfinUser` means the existing multi-profile reactivity carries it along for free; no second source of truth.

## Permission detection

`JellyfinUser` adds a `Policy` sub-struct:

```swift
extension JellyfinUser {
    struct Policy: Codable, Sendable, Equatable {
        let isAdministrator: Bool
        let enableContentDeletion: Bool
    }
    let policy: Policy?
}
```

The `Policy` field is optional because some Jellyfin API responses don't include it (e.g. `/Users/Public` returns sparse user objects without policy). `getCurrentUser()` always returns it.

### Reactivity across profile switches

`AppState.activeUser` is `@Observable` and gets replaced atomically by the existing auth flow at three points:
1. **Login** (`AppState.setAuthenticated(server:user:)` line 52 of `AppState.swift`) → sets `activeUser` to the new user with their policy.
2. **Logout** (`AppState.signOut()` line 60) → sets `activeUser` to `nil`.
3. **Profile switch** (`LaunchProfilePickerView` → `AppRouter` → `DependencyContainer.switchToUser` → eventually `setAuthenticated` with the new user) → replaces `activeUser` atomically.

Because `activeUser` is `@Observable` and detail views read it via SwiftUI's environment, **the delete button's visibility recomputes automatically on every transition.** No imperative refresh, no cache invalidation:

```swift
private var canDelete: Bool {
    guard let policy = appState.activeUser?.policy else { return false }
    return policy.isAdministrator || policy.enableContentDeletion
}
```

When `activeUser` flips from User A (admin) to User B (regular), the `canDelete` computed property re-evaluates and SwiftUI re-renders the detail view, removing the button. The reverse holds. Same for the in-flight case where a Delete confirmation sheet is already open: SwiftUI keeps the sheet's local state but the underlying detail view's button visibility tracks the live policy. If the policy goes from yes→no mid-confirmation, the worst case is the user can still confirm; the server-side `DELETE /Items/{id}` then returns 403 and the partial-success toast surfaces the denial. We do not chase the in-flight case in the UI; the server is the final gate.

The `isAdministrator` shortcut covers admins whose individual `enableContentDeletion` flag is incidentally false (admins implicitly have all rights in Jellyfin).

### What happens during the policy-fetch window

There's a brief window between "auth succeeded" and "getCurrentUser() returned". During that window `activeUser` could either be nil or the cached value from a prior session. To keep the button visibility honest:

- The login flow calls `getCurrentUser()` as part of its handshake (`JellyfinAuthService.getCurrentUser()` is already invoked at line 64 of `JellyfinAuthService.swift`), so `activeUser` is only ever set with a policy already attached.
- Profile-switch goes through the same path. The window doesn't exist in practice.
- For the legacy session-restore path (returning to an existing session at app launch), the cached `JellyfinUser` may pre-date the policy decode. The first `getCurrentUser()` call after launch updates `activeUser` with a fresh user-object. Until then, `activeUser.policy` is nil → `canDelete` is false → button hidden. Conservative default.

## MediaDeletionService

```swift
protocol MediaDeletionService {
    func deleteMovie(itemId: String, cascadeToArrStack: Bool) async throws
    func deleteSeries(itemId: String, cascadeToArrStack: Bool) async throws
    func deleteSeasons(itemId: String, seasonItemIDs: [String], cascadeToArrStack: Bool) async throws
}

struct MediaDeletionError: Error {
    enum Stage { case jellyfin, seerr }
    let stage: Stage
    let underlying: Error
    let partialSuccess: Bool  // true if Jellyfin succeeded but Seerr failed
}
```

Implementation flow per method:

**`deleteMovie`:**
1. Call `JellyfinItemService.deleteItem(id:)` (Jellyfin `DELETE /Items/{itemId}`).
2. If `cascadeToArrStack`: look up the Seerr media-id from the cached SeerrMedia for this TMDB ID; if found, call `SeerrMediaService.deleteMediaFile(seerrMediaId:)`.
3. Surface `MediaDeletionError(stage: .seerr, partialSuccess: true)` if Seerr fails after Jellyfin succeeds — the file is already gone from Jellyfin, so we report the partial state rather than rolling back.

**`deleteSeries`:**
1. `DELETE /Items/{seriesItemId}` — Jellyfin recursively removes all seasons + episodes.
2. If `cascadeToArrStack`: same Seerr lookup + `deleteMediaFile` call.

**`deleteSeasons`:**
1. Loop over `seasonItemIDs`, call `DELETE /Items/{seasonItemId}` per season.
2. `cascadeToArrStack` parameter is accepted but **ignored**. The service emits a warning log and the UI prevents the toggle from being ON in the first place (see UI section below). This is because Jellyseerr's media-delete endpoint can only remove the entire Sonarr series, not individual seasons. The asymmetry is documented in code comments and surfaced to the user as a disabled toggle with tooltip.

Why two API surface additions instead of one?
- `JellyfinItemService.deleteItem` is generic across movies, series, and seasons because Jellyfin's `DELETE /Items/{id}` handles all three.
- `SeerrMediaService.deleteMediaFile` is the existing Seerr `DELETE /api/v1/media/{id}/file` endpoint, which under the hood calls Radarr's `removeMovie` or Sonarr's `removeSeries` (verified against Jellyseerr's `server/routes/media.ts` and `server/api/servarr/radarr.ts`/`sonarr.ts`). The `deleteFiles: true` parameter Jellyseerr passes to Radarr/Sonarr is a no-op for us because Jellyfin already deleted the file in step 1.

## UI: where the buttons live

**MovieDetailView.** Add a "Delete..." button to the action row. Visibility is gated on `canDelete`. Tapping it presents `MediaDeletionSheet` configured for a single movie.

**SeriesDetailView.** Add a "Delete..." button to the series chrome (alongside Play / Resume). Same `canDelete` gate. Tapping it presents `MediaDeletionSheet` configured for a series; the sheet's body offers a choice:

- A toggle at the top: "Delete entire series" (default OFF).
- Below the toggle: a checkbox list of all seasons. When "Delete entire series" is ON, the season checkboxes are disabled with all-greyed-out styling.
- A confirm button at the bottom: "Delete" with a destructive accent. Disabled while no season is selected AND "Delete entire series" is OFF.

**MediaDeletionSheet for the movie case** has no season picker — just the title of the movie, a single "Also remove from Radarr/Sonarr" toggle (default ON), and the Delete / Cancel buttons.

**MediaDeletionSheet for the series case** has, in addition:
- The series title + the count of items being deleted ("3 seasons" / "Entire series, 6 seasons").
- The cascade toggle, with state-dependent behavior:
  - **"Delete entire series" mode**: cascade toggle is enabled, default ON, label "Also remove from Sonarr".
  - **Single or multi-season mode**: cascade toggle is forced OFF and disabled, with a footnote in the sheet: "Sonarr only supports removing the entire series. To also remove from Sonarr, delete the whole series instead."

## Confirmation UX

The sheet uses tvOS focus engine conventions:

- Initial focus on the **Cancel** button. Destructive Default-Cancel is a system pattern that prevents accidental deletion via the touch surface.
- The Delete button uses `.role(.destructive)` so it renders red and announces destructive intent to VoiceOver.
- Menu key dismisses the sheet without confirming.

After confirmation:

1. The sheet itself stays open and shows a `ProgressView`.
2. On success: sheet dismisses, the detail view pops back to its parent. The library cache is invalidated (existing `FilterCache.clear()` pattern, plus the home-screen re-fetches on next focus).
3. On failure with `partialSuccess: true`: sheet shows a toast "Removed from Jellyfin, but failed to update Radarr/Sonarr. The file is gone but the *arr entry still exists." with an OK button.
4. On failure with `partialSuccess: false`: sheet shows a toast "Failed to delete. The library is unchanged." with an OK button.

## API contract

**Jellyfin:** `DELETE /Items/{itemId}` — empty body, 204 No Content on success, 401 on auth fail, 403 if user lacks deletion right (even though we gate the UI). We handle 403 as a user-visible toast in case the policy changes between login and delete attempt.

**Seerr:** `DELETE /api/v1/media/{seerrMediaId}/file?is4k=false` — 204 No Content on success. 403 if the Seerr user lacks `MANAGE_REQUESTS`. 404 if the Seerr media-id doesn't exist (we silently no-op in this case, since "not in Seerr" is the same as "successfully removed from Seerr"). The `is4k` query parameter is always `false` for Sodalite's use case (no 4K profile distinction in our flow).

The Seerr media-id lookup uses the same SeerrMedia cache the Catalog feature already populates. If the cache doesn't have a record for the TMDB-id of the deleted item, we treat the cascade as a no-op success (the user wanted "also from Sonarr" but Sonarr never knew about this title).

## Error handling

- Network errors on the Jellyfin call: abort, show "Failed to delete from Jellyfin" toast.
- Network errors on the Seerr cascade call after Jellyfin succeeded: show "Partial success" toast as described above.
- Permission errors (403) after the gate already passed: show "Server denied delete request" toast.
- Concurrency: if two delete sheets are open (rare on tvOS but possible across tabs), each call goes to its own `Task`. No locking.

## Testing

No test target. Manual verification:

1. Log in as a user without `EnableContentDeletion`. Open a movie detail. Confirm no Delete button.
2. Log in as an admin. Open a movie detail. Confirm Delete button is present.
3. Delete a movie with cascade OFF. Verify the file is gone from Jellyfin (check via `gh api` or web UI). Verify Radarr still has the entry.
4. Delete a movie with cascade ON. Verify Radarr no longer has the entry.
5. Open a series. Delete entire series with cascade ON. Verify Sonarr no longer has the series.
6. Open a series. Delete two specific seasons (no cascade option). Verify the seasons are gone from Jellyfin, Sonarr is unchanged.
7. Confirm the cascade toggle is disabled and explained when only seasons (not the whole series) are selected.
8. Network down during the Seerr call: confirm partial-success toast.
9. After delete, confirm the library/home cache refreshes and the deleted item no longer appears.

**Profile-switch verification (this matters because Sodalite has a multi-profile launch picker):**

10. Have two Jellyfin users configured on the same server: User A (admin or `EnableContentDeletion = true`) and User B (`EnableContentDeletion = false`).
11. Log in as User A. Open a movie detail. Confirm the Delete button is visible.
12. Without closing the app, go back to the launch profile picker and switch to User B. Re-open the same movie detail. Confirm the Delete button has disappeared.
13. Switch back to User A. Confirm the Delete button returns.
14. Cold-launch the app while session-restore is active. During the brief window before `getCurrentUser()` completes, confirm the Delete button is hidden (conservative default), then watch it appear once the policy lands. Should be visually imperceptible on a fast network.
15. Log out completely from the Settings screen. Re-log in as User B. Confirm the button stays hidden.

## Risk and trade-offs

- The cascade-disabled-for-seasons asymmetry. Risk: user expects "Remove from Sonarr" to work for season-level deletes. Mitigation: the toggle is forcibly disabled with a clear footnote. Trade-off: rather than failing silently or doing something surprising, we hide the option.
- `Policy.enableContentDeletion` is a server-wide flag the admin sets per user. If the admin changes the flag while a user is logged in, the UI doesn't update until the next `getCurrentUser()` call. Acceptable.
- The Seerr media-id lookup uses the Catalog cache. If a user comes from a deep-link straight into the detail of an item the catalog hasn't surfaced, the cache may not have the entry. We fall back to a Seerr search by TMDB-id at delete time if the cache misses.

## Future work, explicitly deferred

- Episode-level delete. Out per Vincent's design call.
- Per-folder permissions (`EnableContentDeletionFromFolders`). Defer until a real user has the access pattern.
- Bulk operations (delete N movies from the Library at once). The single-item flow needs to ship and stabilise first.
