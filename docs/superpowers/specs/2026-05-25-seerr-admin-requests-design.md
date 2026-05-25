# Seerr Admin Requests

Date: 2026-05-25
Status: approved, ready for implementation plan
Tracking: Sub-project B of the "admin features" pair (A was file management, shipped 2026-05-24)

## Motivation

Sodalite already lets users create Seerr requests from the Catalog and watch their own queue in "Meine Anfragen". What's missing is the other side: an admin's queue. Today, to approve, decline, edit, or delete a pending request an admin has to leave Sodalite and open the Jellyseerr web UI. That breaks the "stay in one app" promise that the file-management feature also addressed.

Goal: from inside Sodalite, an authorised user (Jellyseerr `MANAGE_REQUESTS` or `ADMIN` permission) can see all requests across all users, filtered by status, and act on them: approve, decline, edit (target server / quality profile / root folder / seasons), or delete the request entry.

## Scope

In scope:

- Decode the `permissions` bitfield from Jellyseerr's `auth/me` response into `SeerrUser`.
- New `SeerrPermissions` value type that interprets the bitfield (`ADMIN`, `MANAGE_REQUESTS`, plus any others we reference). Helpers like `SeerrUser.canManageRequests`.
- Extend `SeerrRequestService` with five new methods: `allRequests`, `approveRequest`, `declineRequest`, `deleteRequest`, `updateRequest`.
- New `CatalogAllRequestsView` as a third Catalog sub-tab labeled "Alle Anfragen", visible only when the active Seerr user can manage requests.
- Filter chips at top of the view (Pending, Approved, Declined, Alle) with counts.
- Row-level action buttons (Approve, Edit, Decline, Delete), context-sensitive per request status.
- A reusable `SeerrRequestEditSheet` with Server, Quality Profile, Root Folder pickers, plus a Season multi-select for TV requests.
- Lightweight confirmation alerts for destructive actions (Decline, Delete). No confirm for Approve or Edit-Save.
- Lazy pagination (50 per page, infinite scroll).
- Localised in all 26 languages on first ship.

Out of scope:

- A separate top-level Admin tab. The Catalog sub-tab keeps the feature scoped; if 2-3 more admin features land later, promote to a dedicated tab (small refactor).
- Inline admin actions on `CatalogDetailView`. Admin work lives in the admin queue, not on browse surfaces.
- Bulk select (approve/decline N at a time). Power-user feature, can come later.
- Retry-failed-request action. Specialised; out of scope MVP.
- Push / in-app notifications when a new pending request arrives.
- Editing Language Profile or Sonarr/Radarr tags. The three pickers (Server, Profile, Root Folder) plus Season multi-select cover the common "wrong target" correction.
- Editing 4K-vs-non-4K split. Requests keep whatever 4K flag they were created with.

## Architecture

```
Sodalite
├── Models/Seerr/
│   ├── SeerrUser.swift                       (modified: permissions: Int?)
│   ├── SeerrPermissions.swift                (new: bitfield + helpers)
│   ├── SeerrRequestFilter.swift              (new: pending|approved|declined|all)
│   └── SeerrRequestUpdateBody.swift          (new: optional fields)
├── Services/Seerr/
│   ├── SeerrEndpoints.swift                  (modified: 5 new endpoints)
│   ├── SeerrRequestService.swift             (modified: 5 new methods)
│   └── SeerrAuthService.swift                (modified: response includes permissions)
├── Features/Catalog/
│   ├── CatalogView.swift                     (modified: 3rd segment gated on permissions)
│   ├── CatalogViewModel.swift                (modified: allRequests state + filter logic)
│   ├── CatalogAllRequestsView.swift          (new)
│   ├── SeerrRequestAdminRow.swift            (new: row with action buttons)
│   └── SeerrRequestEditSheet.swift           (new: Server/Profile/Root/Seasons picker sheet)
└── Localizable.xcstrings                     (modified: ~25 new keys × 26 locales)
```

`SeerrRequestService` is the single boundary the Catalog layer talks to. `CatalogAllRequestsView` never calls Jellyseerr endpoints directly.

`AppState.activeSeerrUser` is the permission source of truth (already populated via `SeerrAuthService.me()` on login + restore). The new `permissions` field flows through that existing pipe; no new state container.

## Permission detection

`SeerrUser` adds `permissions: Int?`:

```swift
struct SeerrUser: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let email: String?
    let username: String?
    let displayName: String?
    let avatar: String?
    let userType: Int?
    let requestCount: Int?
    let permissions: Int?
}
```

Optional because older Jellyseerr installs (pre-2.0?) may not return the field, and the in-app cached `SeerrUser` snapshots stored before this change ship without it. Default treatment when nil: no admin rights.

`SeerrPermissions` is a `RawRepresentable` bitfield enum mirroring Jellyseerr's `server/lib/permissions.ts`:

```swift
struct SeerrPermissions: OptionSet, Sendable {
    let rawValue: Int
    static let none           = SeerrPermissions(rawValue: 0)
    static let admin          = SeerrPermissions(rawValue: 2)
    static let manageSettings = SeerrPermissions(rawValue: 4)
    static let manageUsers    = SeerrPermissions(rawValue: 8)
    static let manageRequests = SeerrPermissions(rawValue: 16)
    static let request        = SeerrPermissions(rawValue: 32)
    static let autoApprove    = SeerrPermissions(rawValue: 256)
    // ... only the values we actually check are listed; rest live in
    // Jellyseerr's enum and we don't need them today.
}
```

User-facing helper on `SeerrUser`:

```swift
extension SeerrUser {
    var canManageRequests: Bool {
        let mask = SeerrPermissions(rawValue: permissions ?? 0)
        return mask.contains(.admin) || mask.contains(.manageRequests)
    }
}
```

`CatalogView` gates the third tab on `appState.activeSeerrUser?.canManageRequests == true`. A 403 from any admin endpoint surfaces as a toast in case the server-side permission was revoked between login and action.

## SeerrRequestService extensions

```swift
protocol SeerrRequestServiceProtocol: Sendable {
    // ... existing ...

    func allRequests(
        filter: SeerrRequestFilter,
        take: Int,
        skip: Int
    ) async throws -> SeerrRequestsResult

    @discardableResult
    func approveRequest(requestID: Int) async throws -> SeerrRequest

    @discardableResult
    func declineRequest(requestID: Int) async throws -> SeerrRequest

    func deleteRequest(requestID: Int) async throws

    @discardableResult
    func updateRequest(
        requestID: Int,
        body: SeerrRequestUpdateBody
    ) async throws -> SeerrRequest
}
```

Endpoint additions to `SeerrEndpoints.swift`:

```swift
case allRequests(filter: SeerrRequestFilter, take: Int, skip: Int)
    // GET /api/v1/request?take=X&skip=X&filter=pending&sort=added
case approveRequest(requestID: Int)
    // POST /api/v1/request/:id/approve
case declineRequest(requestID: Int)
    // POST /api/v1/request/:id/decline
case deleteRequest(requestID: Int)
    // DELETE /api/v1/request/:id
case updateRequest(requestID: Int, body: SeerrRequestUpdateBody)
    // PUT /api/v1/request/:id
```

`SeerrRequestFilter` is an enum encoded into the `filter` query parameter:

```swift
enum SeerrRequestFilter: String, Codable, Sendable, CaseIterable {
    case pending  = "pending"
    case approved = "approved"
    case declined = "declined"
    case all      = "all"
}
```

`SeerrRequestUpdateBody` mirrors Jellyseerr's `PUT /api/v1/request/:id` body, all fields optional so we only send what changed:

```swift
struct SeerrRequestUpdateBody: Encodable, Sendable {
    let serverId: Int?
    let profileId: Int?
    let rootFolder: String?
    let languageProfileId: Int?  // Sonarr only; nil for movies
    let seasons: [Int]?          // Sonarr only; nil for movies
    let userId: Int?             // requestedBy reassignment; we don't surface this today, kept for future
}
```

Server / profile / root folder lookups for the Edit sheet use the existing `radarrServers` / `radarrDetails(serverID:)` and `sonarrServers` / `sonarrDetails(serverID:)` endpoint cases. No new service for that.

## CatalogView integration

`CatalogView` currently shows a two-segment `Picker` for Discover / My Requests. Becomes three segments, third hidden for non-admins:

```swift
Picker("", selection: $viewModel.selectedTab) {
    Text("catalog.tab.discover").tag(CatalogTab.discover)
    Text("catalog.tab.myRequests").tag(CatalogTab.myRequests)
    if appState.activeSeerrUser?.canManageRequests == true {
        Text("catalog.tab.allRequests").tag(CatalogTab.allRequests)
    }
}
.pickerStyle(.segmented)
```

`CatalogTab` enum gains `case allRequests`.

`CatalogViewModel` gains:

```swift
var allRequests: [SeerrRequest] = []
var allRequestsFilter: SeerrRequestFilter = .pending
var allRequestsCounts: [SeerrRequestFilter: Int] = [:]   // for chip badges
var isLoadingAllRequests: Bool = false
var isLoadingMoreAllRequests: Bool = false
private var allRequestsTotal: Int = 0
private var allRequestsSkip: Int = 0

func loadAllRequests(reset: Bool) async {
    if reset { allRequestsSkip = 0; allRequests = [] }
    // fetch one page, append, update total + skip
}
func loadMoreAllRequests() async {
    guard allRequests.count < allRequestsTotal, !isLoadingMoreAllRequests else { return }
    // next page
}
func setFilter(_ filter: SeerrRequestFilter) async {
    allRequestsFilter = filter
    await loadAllRequests(reset: true)
}
func refreshAllRequestsCounts() async {
    // parallel fetch of 4 pageInfo.results via `take=0` requests
}
```

Approve / Decline / Delete / Update methods on the VM call the service, mutate the local row optimistically (Approve flips status to `.approved`), then re-fetch counts. If the row's new status no longer matches the active filter (e.g. Pending → Approved while filter is `pending`), the VM removes it from the local array.

## CatalogAllRequestsView layout

```
┌────────────────────────────────────────────────────────────────┐
│  Pending 12  Approved 47  Declined 3  Alle 62                 │ ← Filter chips
├────────────────────────────────────────────────────────────────┤
│  ┌─────┬─────────────────────────────────────────────────┐    │
│  │     │ Cars (2006) · Movie                              │    │
│  │poster│ Angefragt von vince · vor 2 Std                  │    │
│  │     │ [Genehmigen] [Bearbeiten] [Ablehnen] [Löschen]   │    │
│  └─────┴─────────────────────────────────────────────────┘    │
│  ┌─────┬─────────────────────────────────────────────────┐    │
│  │     │ The Bear (2022) · Series · 3 Staffeln            │    │
│  │poster│ Angefragt von anna · vor 5 Std                   │    │
│  │     │ [Genehmigen] [Bearbeiten] [Ablehnen] [Löschen]   │    │
│  └─────┴─────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────────┘
```

Filter chips: horizontal `HStack` of `Button`s, each styled as a pill, selected one filled with `.tint`, unselected with `Color.white.opacity(0.08)`. Count badge appended to the label. Match `[[sodalite-ui-focus-and-tint]]` — never `Color.accentColor`, always `.tint`. Focus stroke pink, not blue.

Row: `SeerrRequestAdminRow` — poster (cached image, same fetch path as `SeerrRequestRow`), title + year + type + season count (for TV), "Angefragt von <displayName>" + relative time, action button row.

Action buttons use `GlassActionButton` (same as `MediaDeletionSheet` footer) for visual consistency with the deletion feature. Visibility per status:

- `.pending`: Approve (`.borderedProminent` + accent tint) + Edit + Decline + Delete
- `.approved`: Edit + Delete   (Approve hidden; row is already approved)
- `.declined`: Delete only      (re-approving a declined request is rare; user can edit-then-approve if needed by reopening)
- `.failed`: Delete only        (retry is out of scope; user can delete + re-request from CatalogDetail)

Pagination: `LazyVStack` with each row's `.onAppear` checking "am I the last row, and is there more to load?" to trigger `loadMoreAllRequests()`. Take=50 per page. A small `ProgressView` at the bottom while `isLoadingMoreAllRequests`.

Empty state: tray icon + "Keine Anfragen mit diesem Filter" message. Error state: triangle icon + error message + retry button (same pattern as `CatalogMyRequestsView`).

## SeerrRequestEditSheet

Modal-presented from the Edit button in `SeerrRequestAdminRow`. tvOS modal, focus initially on the first picker.

```
┌──────────────────────────────────────────────────┐
│  Anfrage bearbeiten                               │
│  Cars (2006) · Angefragt von vince                │
├──────────────────────────────────────────────────┤
│  Radarr-Server         [Server A           ▾]    │
│  Quality Profile       [HD-1080p           ▾]    │
│  Root Folder           [/media/movies      ▾]    │
│                                                    │
│  (TV only)                                         │
│  Staffeln                                          │
│   ☑ Staffel 1                                      │
│   ☑ Staffel 2                                      │
│   ☐ Staffel 3                                      │
├──────────────────────────────────────────────────┤
│  [Abbrechen]                       [Speichern]    │
└──────────────────────────────────────────────────┘
```

Initial state: pickers pre-populated from the request's current `serviceId` / `profileId` / `rootFolder` (extracted from the `SeerrRequest.media` object) and seasons from `request.seasons`.

On open, the sheet fires three parallel requests:
1. `radarrServers()` (for movie) or `sonarrServers()` (for series) — to populate the Server picker.
2. `radarrDetails(serverID:)` for the currently-selected server — to populate Profile + Root Folder pickers.
3. (No-op if data is missing from request; pickers stay disabled with a "Lädt..." label until ready.)

When the user changes the Server picker, fire a fresh `radarrDetails(serverID:)` for the new server and reset Profile + Root Folder selections to that server's defaults (highlighted with "(Standard)" suffix).

Save constructs a `SeerrRequestUpdateBody` with only the fields that differ from the original request and calls `updateRequest`. On success: sheet dismisses, parent VM refreshes the row in `allRequests`. On error: inline error message at the bottom of the sheet, sheet stays open.

For TV: season multi-select. Seasons are checkboxes (same `BoolPillRow` pattern from `MediaDeletionSheet` — note [[sodalite-ui-focus-and-tint]] rules: `.focusable(true)` not `Button`, `.tint` not `Color.accentColor`).

## Confirmation UX

- **Approve:** No confirmation. Row instantly updates; status badge flips. If filter is `pending`, row slides out of the list (the active filter no longer matches).
- **Edit:** Save in the sheet IS the confirmation. No second prompt.
- **Decline:** `Alert("Anfrage ablehnen?", "<title> wird abgelehnt. Kann später noch gelöscht werden.")` with Cancel / Decline.
- **Delete:** `Alert("Anfrage löschen?", "<title> wird aus Jellyseerr entfernt. Die Datei bleibt unverändert wenn schon heruntergeladen.")` with Cancel / Delete.

Both alerts use SwiftUI's `.alert(...)` modifier (not a custom sheet) — these actions are Seerr-only and less destructive than file deletion, so the heavier `MediaDeletionSheet`-style sheet would be overkill.

## API contract

**Jellyseerr** (verified against jellyseerr `server/routes/request.ts`):

- `GET /api/v1/request?take=50&skip=0&filter=pending&sort=added` — returns `{ pageInfo, results: [SeerrRequest] }`. The `pageInfo.results` field gives the total count for the filter; we use it for pagination + chip badges.
- `POST /api/v1/request/:id/approve` — 200 with updated `SeerrRequest`. 403 if user lacks `MANAGE_REQUESTS`. 404 if request already deleted.
- `POST /api/v1/request/:id/decline` — same shape as approve.
- `DELETE /api/v1/request/:id` — 204 No Content. 403 / 404 same.
- `PUT /api/v1/request/:id` — body is `SeerrRequestUpdateBody`. 200 with updated `SeerrRequest`. 400 if the new server/profile/root combination is invalid (e.g. profile doesn't exist on the new server).

For Approve/Decline/Delete: the request body is empty. Some Jellyseerr versions accept a body on approve (notify-on flag etc.); we send empty.

For Update: only include fields that changed (Jellyseerr accepts partial bodies and ignores missing fields).

## Error handling

- **Network errors:** Toast at bottom of screen, "Aktion fehlgeschlagen, bitte erneut versuchen". Row state unchanged.
- **403 Permission denied:** Toast "Server hat die Aktion abgelehnt". Reload current user's `auth/me` to refresh local permissions (the server-side permission may have been revoked since login). If the reload shows no admin rights anymore, navigate back to Discover and hide the tab.
- **404 Request gone:** Silent reload of the current filter page. Row disappears.
- **Edit sheet load failure (Radarr/Sonarr server list fetch):** Sheet shows "Server-Daten konnten nicht geladen werden" with Retry button. Cancel button remains.
- **Update with invalid combination (400):** Sheet shows the error message inline, doesn't dismiss. User can correct and retry.
- **Concurrency:** Two admins acting on the same request — Jellyseerr returns the latest state on each call; our local row update wins for the in-app view. No locking. If the user approves a request that another admin just deleted (404), the silent reload kicks in.

## Localisation

26 languages, all strings in `Sodalite/Localizable.xcstrings`. New keys (German base):

- `catalog.tab.allRequests` → "Alle Anfragen"
- `catalog.allRequests.filter.pending` → "Offen"
- `catalog.allRequests.filter.approved` → "Genehmigt"
- `catalog.allRequests.filter.declined` → "Abgelehnt"
- `catalog.allRequests.filter.all` → "Alle"
- `catalog.allRequests.empty.pending` → "Keine offenen Anfragen"
- `catalog.allRequests.empty.approved` → "Keine genehmigten Anfragen"
- `catalog.allRequests.empty.declined` → "Keine abgelehnten Anfragen"
- `catalog.allRequests.empty.all` → "Keine Anfragen"
- `catalog.allRequests.action.approve` → "Genehmigen"
- `catalog.allRequests.action.edit` → "Bearbeiten"
- `catalog.allRequests.action.decline` → "Ablehnen"
- `catalog.allRequests.action.delete` → "Löschen"
- `catalog.allRequests.requestedBy` → "Angefragt von %@"
- `catalog.allRequests.seasonsCount` → "%d Staffeln"
- `catalog.allRequests.confirm.decline.title` → "Anfrage ablehnen?"
- `catalog.allRequests.confirm.decline.message` → "%@ wird abgelehnt. Kann später noch gelöscht werden."
- `catalog.allRequests.confirm.delete.title` → "Anfrage löschen?"
- `catalog.allRequests.confirm.delete.message` → "%@ wird aus Jellyseerr entfernt. Die Datei bleibt unverändert wenn schon heruntergeladen."
- `catalog.allRequests.toast.approved` → "Anfrage genehmigt"
- `catalog.allRequests.toast.declined` → "Anfrage abgelehnt"
- `catalog.allRequests.toast.deleted` → "Anfrage gelöscht"
- `catalog.allRequests.toast.updated` → "Anfrage aktualisiert"
- `catalog.allRequests.toast.failed` → "Aktion fehlgeschlagen, bitte erneut versuchen"
- `catalog.allRequests.toast.permissionDenied` → "Server hat die Aktion abgelehnt"
- `catalog.allRequests.edit.title` → "Anfrage bearbeiten"
- `catalog.allRequests.edit.server.radarr` → "Radarr-Server"
- `catalog.allRequests.edit.server.sonarr` → "Sonarr-Server"
- `catalog.allRequests.edit.profile` → "Quality Profile"
- `catalog.allRequests.edit.rootFolder` → "Root Folder"
- `catalog.allRequests.edit.seasons` → "Staffeln"
- `catalog.allRequests.edit.save` → "Speichern"
- `catalog.allRequests.edit.loading` → "Lädt..."
- `catalog.allRequests.edit.serverLoadError` → "Server-Daten konnten nicht geladen werden"

Edit-sheet uses existing `common.cancel` for the Cancel button.

When splicing generated translations, run the existing sed pipeline (`sed -i '' 's/"\([^"]*\)": {/"\1" : {/g' generated.json`) so Xcode's exact spacing is preserved (otherwise expect a 37k-line cosmetic diff, see [[xcstrings-pipeline]]).

## Testing

No test target. Manual verification:

1. **Permission gate:** Log in as a non-admin Seerr user. Open Catalog. Confirm the "Alle Anfragen" segment is not visible.
2. **Permission gate (admin):** Log in as a Seerr admin. Open Catalog. Confirm the segment is visible.
3. **List load:** Switch to "Alle Anfragen". Confirm Pending filter is active by default, count badge matches Jellyseerr web UI.
4. **Filter switching:** Click each filter chip. Confirm count badge, list refreshes, empty state appears when count is 0.
5. **Pagination:** With > 50 pending requests, scroll to bottom. Confirm next page loads, no duplicates.
6. **Approve:** Approve a movie request. Confirm Radarr received the title. Confirm Sodalite row flipped out of Pending filter; chip count decremented.
7. **Decline:** Decline a request. Confirm confirmation alert shows, then row flips to Declined.
8. **Delete:** Delete a request. Confirm confirmation alert shows, row removed.
9. **Edit (Movie, change server):** Open Edit on a pending movie request. Change Server. Save. Confirm Radarr received it on the new server.
10. **Edit (Series, change seasons):** Open Edit on a pending series request. Uncheck one season. Save. Confirm Sonarr requests only the remaining seasons.
11. **Edit error path:** Disconnect Radarr/Sonarr backend in Jellyseerr. Open Edit. Confirm load-failure state with Retry.
12. **403 path:** Revoke `MANAGE_REQUESTS` from the test admin while logged in. Try to approve. Confirm 403 toast + tab disappears on permissions reload.
13. **404 path:** Delete a request in the Jellyseerr web UI while it's visible in Sodalite's Pending list. Try to approve it from Sodalite. Confirm silent reload removes the stale row.
14. **Localisation spot-check:** Switch device language to French + Japanese, confirm new strings render.

## Risk and trade-offs

- **`permissions` decoded but cached.** `AppState.activeSeerrUser` is refreshed at login + restore but not on every action. A permission change mid-session shows up only when the user navigates back to a screen that triggers a refresh, or via the 403-fallback toast. Acceptable.
- **`SeerrRequestUpdateBody` is partial-only.** We send only changed fields. Server expects this per Jellyseerr docs but if a future Jellyseerr version requires full bodies, we'd see 400 on Save. Detect early via the manual-test pass.
- **No edit on `.approved` requests for movies/series after they've been sent to Radarr/Sonarr.** Jellyseerr allows this (you can re-target an already-sent request and it'll re-queue), but the workflow is rare and the UI would need to show "this will re-queue in *arr" warning. Out of scope MVP; revisit if requested.
- **Filter chip counts require a separate parallel fetch.** Four `take=0` requests on initial load + after any action. Cheap (Jellyseerr returns just pageInfo) but introduces a small loading flicker on the chips. Acceptable.
- **Catalog sub-tab vs. main Admin tab.** Current placement is right when this is the only admin feature. If 2+ more admin features land (Jellyfin user management, library scan, server status), revisit promotion to a top-level Admin tab. Migration is a CatalogView + view-model refactor, ~half a day's work.
- **Engine-of-change for visual consistency.** Buttons and rows use the patterns established in `MediaDeletionSheet` and `ValuePickerRow`. Stick to the [[sodalite-ui-focus-and-tint]] rules: `.tint` ShapeStyle not `Color.accentColor`, `.focusable(true)` not `Button` over material, focused fills tinted not white. The `BoolPillRow` from the deletion feature is the canonical season-checkbox pattern; reuse it (move to a shared Components folder if needed, or duplicate inline since it's small).
