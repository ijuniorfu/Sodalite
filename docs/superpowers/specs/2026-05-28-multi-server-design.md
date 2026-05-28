# Multi-Server: switch between Jellyfin servers without logout

Date: 2026-05-28

## Problem

Sodalite today is single-server. The keychain holds one `"activeServer"` slot. To use a different Jellyfin server, the user must run `clearSession` (full logout), which wipes the active server, its access token, its remembered profiles, and all per-profile Seerr cookies. Re-entering a previous server means another full discovery + login + (per profile) Seerr re-auth cycle.

The bones for a multi-server world are already in place:

- `JellyfinServer` is a first-class model with a stable Jellyfin-side `id`.
- Most session state is *already* keyed per server: `accessToken_<serverID>`, `userID_<serverID>`, `rememberedUsers_<serverID>`, `jellyfinPassword_<serverID>`, plus Seerr cookies that key off `(jellyfinServerID, jellyfinUserID)`.
- `switchToUser(_:server:)` already swaps the active session to any remembered profile on a given server, including writing the SharedSessionMirror for TopShelf.

The missing pieces are: persistence of more than one server, an API to switch between servers (the analogue of `switchToUser` at the server level), UX entry points to do that, a migration from the single-slot world, and reset of the few pieces of state that *aren't* server-keyed (FilterCache, in-memory client state, home/library carousels).

This spec covers Multi-Server in isolation. Two related features come later as separate big rocks: iCloud-Sync of server + profile metadata across Apple TVs sharing an Apple ID, and tvOS user-profile integration (`TVUserManager` mapping tvOS profiles to (server, Jellyfin profile) tuples).

Tracks GitHub issue [#11](https://github.com/superuser404notfound/Sodalite/issues/11) (the multi-server half).

## Goals

- Hold more than one Jellyfin server in the keychain, with a single active-server pointer.
- Allow the user to switch the active server from the Launch Profile Picker (fast path) and manage the server list from Settings (full path).
- Add a new server through the existing `ServerDiscoveryView` → `LoginView` flow, reachable from both surfaces above.
- Remove a server cleanly: tokens, remembered profiles, Seerr cookies, and the password slot all go with it. Other servers untouched.
- Migrate existing 0.7.0 users silently: their current `"activeServer"` becomes the first entry in the new `knownServers` list with no perceived change at launch.
- Reset the state that isn't server-keyed (FilterCache, JellyfinClient base URL + access token, SharedSessionMirror, home/library carousels) on every server switch, so the next surface the user sees actually reflects the new server.
- Handle expired tokens and unreachable servers without leaving the app in a half-switched state.

## Non-goals

- **No iCloud-Sync of the server list yet.** That is a separate feature, sequenced after this one. The Multi-Server storage schema is designed so the syncable subset (URLs, server display names, profile metadata) is cleanly separable from the lock-to-device subset (tokens, passwords) when iCloud-Sync lands.
- **No tvOS user-profile (`TVUserManager`) integration yet.** That is the second half of issue #11 and is its own follow-up. Multi-Server is shippable and useful on its own (the "test + prod" / "home + remote" use cases DrHurt cited).
- **No simultaneous multi-server playback or cross-server library merging.** Exactly one server is "active" at any moment. Switching is an explicit user action with a visible state transition.
- **No automatic server discovery refresh.** The user picks "Add server" explicitly; the discovery view scans the LAN at that moment, same as today.
- **No re-architecture of `DependencyContainer` into per-server sub-containers.** Approach A from the brainstorm: minimal refactor, single container, server pointer model. This decision is revisited if the tvOS-Profile phase exposes pressure for a split, not before.

## Approach

Approach A from the brainstorm. The container stays monolithic. The keychain grows a `knownServers` list and an `activeServerID` pointer. `switchServer(to:)` becomes a first-class API on the container, alongside the existing `switchToUser(_:server:)`. The UX gains a server header in the Launch Profile Picker plus a Server section in Settings.

### Component 1: Keychain storage

New top-level keychain keys (defined in `KeychainKeys`):

- `knownServers` — JSON-encoded `[JellyfinServer]`. Stable order: most recently added first. New entries are appended at the front by `addServer`.
- `activeServerID` — String. The `JellyfinServer.id` of the currently active server. Must always resolve into an entry of `knownServers` when present.

Unchanged, per-server keys (already in place today):

- `accessToken_<serverID>`, `userID_<serverID>`, `rememberedUsers_<serverID>`, `jellyfinPassword_<serverID>`.
- Seerr cookies keyed off `(jellyfinServerID, jellyfinUserID)`.

The old `"activeServer"` slot (single-server era) is dropped on migration and never read again.

### Component 2: DependencyContainer API

New methods (all `@MainActor`, all throwing on keychain I/O failure):

- `listKnownServers() -> [JellyfinServer]` — decodes `knownServers`, returns empty array if absent.
- `addServer(_ server: JellyfinServer) throws` — upserts by `id`. The most recently added/updated entry sorts first.
- `removeServer(id: String) throws` — deletes that server's `accessToken_<id>`, `userID_<id>`, `rememberedUsers_<id>`, `jellyfinPassword_<id>`, all `(jellyfinServerID == id)` Seerr cookies. Removes the entry from `knownServers`. If the removed server was the active one and at least one other server remains, switches to the most recently added remaining server. If no servers remain, clears `activeServerID` and SharedSessionMirror (the next launch lands in `ServerDiscoveryView`).
- `switchServer(to id: String) throws` — verifies `id` is in `knownServers`, writes `activeServerID`, loads `accessToken_<id>` and `userID_<id>`, sets `jellyfinClient.baseURL` and `accessToken`, writes SharedSessionMirror, restores the per-profile Seerr session for the now-active (server, user) tuple, signals AppState that home + library carousels need to refresh. Does *not* clear `rememberedUsers_<id>` — those persist across switches.
- `activeServer: JellyfinServer?` (computed) — resolves `activeServerID` against `knownServers`. Returns nil if either is missing (fresh install or corrupted state).

Existing `switchToUser(_:server:)` keeps its current signature and behavior. It is called by `switchServer` indirectly (through the restore path) when the target server has at least one remembered user.

`clearSession()` keeps existing scope (full logout: wipes everything for *all* servers), but the per-server "remove this server only" path goes through `removeServer(id:)`.

### Component 3: Launch + switch flow

Cold-start flow (driven by `AppRouter`):

1. `activeServerID` exists and resolves into a `knownServers` entry, and the per-server keychain has a usable token → `restoreSession` runs as today, lands in `TabRootView`.
2. `activeServerID` exists and resolves, but the token is missing or `/Users/Me` probe fails with 401 → `LaunchProfilePickerView` for that server; if no remembered users, `LoginView` for that server.
3. `activeServerID` is missing or doesn't resolve, but `knownServers` is non-empty → repair: pick the most recently added entry, set as `activeServerID`, re-enter flow.
4. `knownServers` is empty → `ServerDiscoveryView` (first-run UX, identical to today).

Server-switch flow (driven by user action):

1. User picks "Server wechseln" or selects another server in the Settings server list.
2. `switchServer(to: targetID)` runs. On success: `FilterCache.shared.clear()`, `JellyfinClient` is reconfigured (baseURL + accessToken), Seerr session is restored for the (newServer, lastActiveUserOnNewServer) tuple if one exists, SharedSessionMirror is rewritten, `AppState.requestHomeRefresh` and `AppState.requestLibraryRefresh` signals fire.
3. AppRouter re-renders: if the new server has a remembered user with a still-valid token, lands in `TabRootView`; otherwise lands in `LaunchProfilePickerView` for the new server.

The State-Reset signals follow the existing `pendingDeepLinkItemID` / `requestContinueWatching` pattern in AppState: feature views observe via `.task(id:)`, no global notification bus.

### Component 4: UX — Launch Profile Picker

The picker grows a server header at the top:

- Card showing the active server: server display name as primary, host (URL host portion) as secondary, focusable.
- Activation on the card opens a server-switch sheet.
- Long-press on the card also opens the same sheet (consistent with the long-press-to-manage pattern on profile rows today).
- The header is rendered unconditionally, also when `knownServers.count == 1`. The sheet for a single-server install still shows that server (marked Aktiv) plus the "Neuer Server" row, which is exactly the entry point a single-server user needs to add a second one without going through Settings first.

Server-switch sheet:

- Lists every entry in `knownServers`. Active server is marked.
- Each row shows server display name, host, and an avatar stack (up to 3 most recent remembered users for that server) as a visual cue.
- Last row: "Neuer Server" — opens `ServerDiscoveryView` in add-mode (see Component 6).
- Selecting a non-active server runs the switch flow. Selecting the active server dismisses the sheet.

Below the header, the profile picker for the active server's remembered users is unchanged.

### Component 5: UX — Settings

A new "Server" section in `SettingsView`:

- Lists every entry in `knownServers`.
- Each row: display name, host, user count, "Aktiv"-badge for the active server.
- Per-row actions (via long-press menu, consistent with how Sodalite handles row-level actions today):
  - "Zu diesem Server wechseln" (hidden for the already-active row).
  - "Server entfernen" with a confirm dialog spelling out that all profiles, tokens, and Seerr sessions for that server are deleted.
- Section footer: "Server hinzufügen" button → same flow as "Neuer Server" in the picker sheet.

### Component 6: Server-add flow

`ServerDiscoveryView` is reused for both first-run onboarding and add-server. The view itself doesn't care which it is; the difference is the post-login handler:

- First-run: `addServer` is implicitly the first entry and `activeServerID` is set in the existing flow (which already writes `"activeServer"` today — rename target).
- Add-server: same `addServer` call, but also automatically sets the new server as active (an Add-flow that doesn't switch leaves the user staring at the old server, which is surprising).

If a user runs the add-flow against a server whose `id` already matches an entry in `knownServers` (e.g. same Jellyfin server, different LAN URL), `addServer` upserts: the URL is updated in place, the existing per-server keychain bucket (token, profiles) is preserved.

### Component 7: Migration

A new `KeychainMigrator` step (the migrator already handles other one-time keychain reshapes):

- If `"activeServer"` keychain entry exists AND `knownServers` is missing → decode the old `JellyfinServer`, encode it as a 1-element `[JellyfinServer]` into `knownServers`, set `activeServerID` to its `id`, delete `"activeServer"`.
- Idempotent: subsequent runs see `knownServers` present and do nothing.
- No other per-server keys move. `accessToken_<id>`, `userID_<id>`, etc. are already correctly scoped.

### Component 8: Error handling

- **Expired token after switch.** After `switchServer` returns, AppRouter probes `/Users/Me`. On 401 the remembered user for that server is dropped from `rememberedUsers_<id>`, the access token is deleted, and the UI lands in `LaunchProfilePickerView` for the new server (which then falls through to `LoginView` if no other users remembered there).
- **Unreachable server during switch.** Network error during the `/Users/Me` probe → toast "Server nicht erreichbar, später erneut versuchen", the switch is rolled back: previous `activeServerID` is restored, `jellyfinClient.baseURL` + `accessToken` re-set to the previous server's values, SharedSessionMirror rewritten back. The user stays on the previous server. No half-switched state is observable to the rest of the app.
- **Removing the last server.** `removeServer` detects the empty post-state, clears `activeServerID`, runs the SharedSessionMirror clear, and posts an AppState signal for "no servers". AppRouter routes to `ServerDiscoveryView`.
- **Removing the active server with other servers present.** `removeServer` triggers a `switchServer` to the most recently added remaining server before deleting the active one's data. The user lands either in that server's TabRoot (if a remembered user has a valid token) or its profile picker.

## Testing

No automated test target exists in this repo. Manual verification covers:

- **Migration**. Install 0.7.0, log into one server, create at least one remembered profile, install the new build. After launch: profile picker shows that server, Settings → Server shows it as Aktiv, all profiles intact, playback works.
- **Two-server happy path.** Add a second server, switch back and forth from both the picker header and Settings. Each server's profile list, library, and home are correct after every switch. Seerr session restores per (server, profile) pair.
- **Expired-token path.** Manually expire one server's token (delete `accessToken_<id>` from the keychain via a one-off helper, or invalidate it on the Jellyfin side). Switch to that server. App lands in profile picker → LoginView for that server. Other server's session is undisturbed.
- **Unreachable-server path.** Switch to a server while the network is down (or while the Jellyfin host is shut down). Toast appears, app stays on the previous server, switching back to a reachable one works.
- **Remove non-active server.** Settings → Server → entry → "Server entfernen" → confirm. That server's tokens, profiles, and Seerr cookies are gone. Other servers untouched. The keychain has no orphaned per-server keys.
- **Remove active server with others present.** Switches to the most recently added remaining server before deleting. UI doesn't flicker into an empty state.
- **Remove last server.** Lands in ServerDiscoveryView. No orphaned keychain entries.
- **TopShelf after switch.** TopShelf reads SharedSessionMirror; after a server switch, the next TopShelf refresh shows the new server's items (the existing `sodalite://item/{id}` deep link continues to resolve into the new active server's item store).

## Future phases (out of scope here)

- **iCloud-Sync (next big rock).** Sync the *syncable* subset of `knownServers` (URL, display name, server ID, addedAt) and `rememberedUsers_<id>` metadata (user ID, name, primary image tag) across Apple TVs that share an Apple ID. Tokens, passwords, and the active-server pointer stay local. CloudKit vs `NSUbiquitousKeyValueStore` decision deferred to that spec; tvOS-26 provisioning needs investigation either way.
- **tvOS User-Profile Integration.** Map `TVUserManager.shared.currentUserIdentifier` to a (serverID, jellyfinUserID) pair. On tvOS profile switch, run `switchServer` + `switchToUser` to land in that pairing's session. UX: long-press Home → tvOS shows native profile sheet → Sodalite responds. The Multi-Server work here lands the storage shape that mapping needs.
