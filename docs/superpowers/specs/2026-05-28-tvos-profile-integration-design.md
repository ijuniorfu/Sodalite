# tvOS Profile Integration: native Apple TV user routing

Date: 2026-05-28

## Problem

Apple TV 4K+ devices in multi-user mode expose `TVUserManager.shared.currentUserIdentifier` — a stable opaque string that identifies who is currently signed in at the system level. Sodalite ignores this completely today. The result is that on a family Apple TV with three system users (Dad, Mom, Kid), Sodalite still presents whichever session was last active. Switching the system user via long-press-Home does not switch Sodalite's session, and TopShelf shows the wrong household member's Continue Watching items on the home screen tile.

The multi-server work just shipped delivers the storage shape this integration needs: `knownServers`, per-server remembered users, a `defaultServerID` pointer. The piece that's missing is the bridge from "which tvOS user am I right now" to "which (server, Jellyfin profile) should Sodalite be in."

This spec covers the integration in isolation. iCloud-Sync of the mapping table across multiple Apple TVs (so Mom's mapping on the bedroom TV matches the living-room TV the moment she signs into both) is left as a follow-up — see Future Phases.

Tracks the second half of GitHub issue [#11](https://github.com/superuser404notfound/Sodalite/issues/11) ("Native user profiles … long press home button, choose user photo and tvOS changes profile"). Multi-server (the first half) shipped under commit range `91cfee68..ae4c0a19`.

## Goals

- React to tvOS user identity on cold launch AND every scene-foreground transition, so the user can switch via long-press-Home and find the right session on next foreground.
- Auto-record a mapping the first time a tvOS user successfully signs into a Sodalite profile, so most users never need to visit any settings screen.
- Allow manual override of the auto-recorded mapping via a new "Apple TV Profile" sub-screen in Settings.
- Isolate TopShelf content per tvOS user: each system user's home-screen tile shows their own Continue Watching / Next Up.
- Degrade gracefully on Apple TVs that do not have multi-user enabled (older models, single-user setups): behave exactly like today.
- Survive the user removing a server or forgetting a remembered profile that a mapping pointed at: the orphan mapping is dropped and the next foreground lands in the default flow.

## Non-goals

- **No iCloud-Sync of mappings yet.** That is a separate big rock. The storage schema is designed to be syncable (UserDefaults-backed, contains only opaque identifiers — no tokens or secrets) so the follow-up is mechanical.
- **No per-tvOS-user playback preferences, home customisation, or favourite-library overrides.** Jellyfin already isolates per-profile state server-side. Sodalite-local prefs stay shared until a user request shows up that needs otherwise.
- **No new tvOS-user creation flow inside Sodalite.** System users live in tvOS Settings; Sodalite just reads who is currently active.
- **No removal of `defaultServerID` / `defaultUserID`.** They remain the fallback when the current tvOS user has no mapping yet. The new flow strictly sits "above" them in priority.

## Approach

### Component 1: Storage

A new `TVProfileMapping` model and a small store on top of UserDefaults.

```swift
struct TVProfileMapping: Codable, Sendable, Equatable {
    let serverID: String
    let jellyfinUserID: String
}
```

Stored under a single UserDefaults key, JSON-encoded `[String: TVProfileMapping]` where the key is the `TVUserManager` identifier. Single key (not per-tvUser keys) so atomic reads and writes stay simple.

```swift
private enum Keys {
    static let mappings = "tvOS.profileMappings"
}
```

No keychain. The mapping contains no token; only identifiers. UserDefaults is the right surface and keeps this syncable later via iCloud KVS.

### Component 2: `TVProfileMappings` container API

A new `@Observable @MainActor final class TVProfileMappings` instantiated once and held by `DependencyContainer` alongside `authPreferences`. API:

- `mapping(for tvUserID: String) -> TVProfileMapping?` — lookup.
- `setMapping(_ mapping: TVProfileMapping?, for tvUserID: String)` — upsert or remove (nil removes).
- `removeMappings(forServer serverID: String)` — wipe every entry whose `serverID` matches. Called by `DependencyContainer.removeServer`.
- `removeMapping(forUser userID: String, on serverID: String)` — wipe entries where both match. Called by `DependencyContainer.forgetUser`.
- `allMappings: [String: TVProfileMapping]` — read-only snapshot for the Settings UI.

All mutations write through to UserDefaults synchronously (mirrors the existing `AuthPreferences` style).

### Component 3: AppRouter lifecycle hooks

A new `resolveTVUserContext()` runs at two moments:

1. Cold launch — at the very top of `performRestore`, BEFORE the existing `defaultServerID` promotion block. The tvOS mapping wins over the user's pinned default if both are present.
2. Scene foreground — observed via a SwiftUI `.task(id: scenePhase)` on AppRouter's body that fires whenever `scenePhase` becomes `.active`.

The function body:

```swift
private func resolveTVUserContext() async {
    guard let tvUserID = currentTVUserID() else {
        // Single-user Apple TV (or multi-user not enabled). Nothing
        // to do; fall through to defaultServerID logic.
        return
    }

    // If a mapping exists, promote it. Override the current active
    // server / user even if defaultServerID is set, the tvOS user
    // is the more specific signal.
    if let mapping = dependencies.tvProfileMappings.mapping(for: tvUserID) {
        let currentServerID = (try? dependencies.keychainService.loadString(
            for: KeychainKeys.activeServerID
        ))
        let currentUserID = (try? dependencies.keychainService.loadString(
            for: KeychainKeys.userID(serverID: mapping.serverID)
        ))
        if currentServerID != mapping.serverID || currentUserID != mapping.jellyfinUserID {
            // Server switch covers the activeServerID pointer + JellyfinClient
            // reconfiguration. switchToUser writes the per-server user slot.
            try? dependencies.switchServer(to: mapping.serverID)
            if let server = dependencies.activeServer,
               let user = dependencies.listRememberedUsers(serverID: mapping.serverID)
                   .first(where: { $0.id == mapping.jellyfinUserID }) {
                try? dependencies.switchToUser(user, server: server)
            }
        }
    }
    // No mapping = let defaultServerID / defaultUserID logic do its job.
}

private func currentTVUserID() -> String? {
    #if os(tvOS)
    if #available(tvOS 13, *) {
        return TVUserManager.shared.currentUserIdentifier
    }
    #endif
    return nil
}
```

The `currentTVUserID()` helper isolates the `#if os(tvOS)` guard so the rest of the file stays platform-clean.

### Component 4: Auto-recording

`DependencyContainer.saveSession` and `switchToUser` both append a step:

```swift
if let tvUserID = AppRouter.currentTVUserID() {
    tvProfileMappings.setMapping(
        TVProfileMapping(serverID: server.id, jellyfinUserID: user.id),
        for: tvUserID
    )
}
```

`currentTVUserID()` becomes a static helper on AppRouter (or moves to its own utility) so it can be called from `DependencyContainer` too. Idempotent: re-recording the same mapping is a no-op.

Auto-recorded mappings are indistinguishable from manually-set ones at the storage level. A user override is just another `setMapping` call, so behaviour stays consistent regardless of how the mapping got there.

### Component 5: `SharedSessionMirror` keyed by tvOS user

Today `SharedSessionMirror.write(serverURL:userID:accessToken:)` writes one blob to the shared keychain. TopShelf reads it directly. With multi-tvOS-user the blob has to be keyed.

New API:

```swift
struct SharedSessionMirror {
    static func write(tvUserID: String?, serverURL: URL, userID: String, accessToken: String)
    static func clear(tvUserID: String?)
    static func read(tvUserID: String?) -> SharedSession?
}
```

`tvUserID == nil` uses the sentinel slot `"default"` (same blob shape as today). The keychain key becomes `tvOSSession_<tvUserID>` or `tvOSSession_default`.

Migration: at first launch on the new build, if the legacy single `sharedSession` slot exists, copy it to `tvOSSession_default` and delete the original. KeychainMigrator gets a new step parallel to the existing `migrateActiveServerToMultiIfNeeded`.

TopShelf's `ContentProvider` change:

```swift
let tvUserID = TVUserManager.shared.currentUserIdentifier  // tvOS extension can see this
guard let session = SharedSessionMirror.read(tvUserID: tvUserID) else { return nil }
```

If the current tvOS user has no session blob (they haven't opened Sodalite yet), TopShelf returns no items — same empty state as the very first launch today.

Every Sodalite-side `SharedSessionMirror.write` / `.clear` call gets updated to pass `currentTVUserID()` so the mirror writes land in the right slot. `clear` should clear ALL slots only on `clearSession()` (full logout); per-server / per-profile teardown clears just the current tvOS user's slot.

### Component 6: Settings UI

A new `TVUserProfileSettingsView` Settings sub-screen, linked from `SettingsView` alongside the new "Servers" entry from the multi-server work.

Layout:

- Title "Apple TV Profile".
- A single section listing all entries in `tvProfileMappings.allMappings`, plus a row for the "current tvOS user" if it has no mapping yet (so the user can set one without having to log in first).
- Each row: tvOS user identifier (or "Currently signed in" for the active one), server name, profile name. Long-press menu offers "Edit mapping" (presents a server + profile picker sheet) and "Remove mapping".
- Footer hint: "Mappings are recorded automatically the first time a tvOS user signs into a profile. Long-press a row to edit or remove."
- Edge: on Apple TVs without multi-user, show a single read-only row labelled "Shared session" with the current (server, profile) and an explanatory caption that multi-user is not active.

The "tvOS user identifier" displayed to the user is the system-supplied string. Apple's API does not expose a human-readable name; this is acceptable for the first cut — users will recognise their own mapping by the (server, profile) pair, and the "Currently signed in" annotation marks the active row. Future work could surface tvOS user names via `TVUserManager.userIdentifier(for:)` callbacks if Apple exposes them in a future tvOS release.

### Component 7: Edge cases

- **Multi-user not enabled.** `currentUserIdentifier` returns nil. All flows that consult tvOS user identity fall back to single-shared-session behaviour: `SharedSessionMirror` uses the `"default"` slot, `resolveTVUserContext` returns immediately, auto-record is skipped. Settings shows the read-only "Shared session" row.
- **Mapped server was removed.** `removeServer(id:)` calls `tvProfileMappings.removeMappings(forServer:)`. Orphan mappings disappear synchronously. Next launch as that tvOS user lands in the default flow (defaultServerID → first remembered server → ServerDiscoveryView).
- **Mapped profile was forgotten.** `forgetUser(id:serverID:)` calls `tvProfileMappings.removeMapping(forUser:on:)`. Orphan dropped. Next launch as that tvOS user lands in the picker for the mapped server (if it still exists) or the default flow.
- **Mapped server exists but token is missing.** `switchServer` writes `activeServerID` and throws `.missingToken`. `resolveTVUserContext` swallows the error (try?) and the AppRouter falls through to the picker for the mapped server. The user re-authenticates. The mapping stays (it was never wrong — just the token expired).
- **First login as a tvOS user with no mapping.** `saveSession` records the mapping after a successful login. Subsequent launches as the same tvOS user route automatically.

### Component 8: Testing (manual; no test target in repo)

- **Multi-user happy path.** On an Apple TV 4K with multi-user enabled, sign in as User A → log into Sodalite as Vince/jelly-arrstack → mapping recorded. Long-press Home → switch to User B → sign in as Vince again on a different profile (or different server) → mapping recorded for B. Long-press Home back to A → reopen Sodalite → land in Vince/jelly-arrstack. Same for B in reverse.
- **TopShelf isolation.** As above, then return to tvOS Home. User A's TopShelf shows Vince's Continue Watching for jelly-arrstack. Switch to User B at the system level → User B's TopShelf shows B's Sodalite session items.
- **Forget mapped profile.** From the Sodalite Profile Picker, long-press → forget Vince. Next launch as that tvOS user → LaunchProfilePicker for the mapped server (still known), with an "Add another profile" entry.
- **Remove mapped server.** Settings → Server Management → remove jelly-arrstack. Next launch as the tvOS user that mapped to it → defaultServerID path; if no default, picker for the most recently added remaining server.
- **Single-user Apple TV.** On an Apple TV HD (no multi-user), or a 4K with multi-user disabled in tvOS Settings: launch Sodalite, behaviour is identical to the multi-server-only build. Settings shows the "Shared session" row.
- **Manual override.** Settings → Apple TV Profile → long-press the current row → Edit → pick a different (server, profile). The new mapping is honoured immediately on the next foreground.

## Future phases (out of scope here)

- **iCloud-Sync of mappings.** Mirror `tvOS.profileMappings` into `NSUbiquitousKeyValueStore` so the same Apple ID across multiple Apple TVs sees the same mapping table. Mostly mechanical given the UserDefaults-backed storage.
- **tvOS user name surfacing.** If Apple ever exposes the system user's display name + avatar (today the API gives only the opaque identifier), surface them in the Apple TV Profile settings list so the rows are easier to identify.
- **Per-tvOS-user playback preferences.** Currently shared across all tvOS users of a single Apple TV. Could be split if user feedback shows demand.
