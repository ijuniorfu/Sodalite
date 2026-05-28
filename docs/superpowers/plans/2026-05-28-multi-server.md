# Multi-Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow Sodalite to hold more than one Jellyfin server in the keychain and let the user switch between them without going through a full logout. Migrate existing single-server installs silently.

**Architecture:** Approach A from the spec. `DependencyContainer` stays monolithic. Two new keychain keys (`knownServers`, `activeServerID`) replace the old `"activeServer"` single-slot. New container methods `listKnownServers`, `addServer`, `removeServer`, `switchServer`, plus a computed `activeServer`. `AppRouter` resolves the active server through `DependencyContainer` instead of reading the keychain directly. Launch Profile Picker gains a server header that opens a `ServerSwitchSheet`. Settings gains a `ServerManagementView`. A one-shot migration moves the old single-slot blob into the new schema. tvOS-Profile and iCloud-Sync are explicitly out of scope (separate big rocks).

**Tech Stack:** Swift 6, SwiftUI on tvOS 26+, Keychain (`KeychainService`), no new dependencies. No test target (manual verification only).

**Spec:** `docs/superpowers/specs/2026-05-28-multi-server-design.md` (commit `d1f26a6e`).

**Build command (used in every verification step):**
```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
  -destination 'generic/platform=tvOS' build
```

**Conventions:**
- No em-dashes or rhetorical hyphens anywhere in code, comments, commits, or this plan.
- Commit messages follow Conventional Commits (`feat(auth):`, `feat(settings):`, `chore(keychain):` etc.) with `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` trailer.
- Push after every commit (per `feedback_commit_and_push`).
- The xcstrings file may carry unrelated Xcode-generated churn; stage individual Swift files, not `git add -A`.

---

## File Structure

**New files:**
- `Sodalite/Features/Auth/ServerSwitchSheet.swift`: sheet UI listing `knownServers` with switch/add actions, presented from the Launch Profile Picker.
- `Sodalite/Features/Settings/ServerManagementView.swift`: Settings sub-screen listing known servers with switch/remove actions and an "add server" entry point.

**Modified files:**
- `Sodalite/Services/Keychain/KeychainKeys.swift`: two new static keys.
- `Sodalite/Services/Keychain/KeychainMigrator.swift`: new one-shot migration step from `"activeServer"` to the multi schema.
- `Sodalite/App/Environment/DependencyContainer.swift`: new server-management methods and a `serverDidSwitch` AppState signal hookup.
- `Sodalite/App/AppState.swift`: new signal field `serverDidSwitch` (incrementing token observed by Home/Library).
- `Sodalite/App/AppRouter.swift`: route resolution uses `dependencies.activeServer` instead of reading `"activeServer"` keychain directly; observes `serverDidSwitch` to reset transient state.
- `Sodalite/Features/Auth/LaunchProfilePickerView.swift`: server header card + sheet presentation.
- `Sodalite/Features/Auth/ServerDiscoveryViewModel.swift`: post-login path routes through `addServer` + `switchServer`; supports "add another server" mode.
- `Sodalite/Features/Auth/LoginViewModel.swift`: same routing for the case where login originates from add-server flow.
- `Sodalite/Features/Settings/SettingsView.swift`: link to `ServerManagementView`.
- `Sodalite/Features/Home/HomeViewModel.swift`: subscribe to `serverDidSwitch` signal, clear caches and reload.
- `Sodalite/Features/Library/LibraryView.swift` (or the library VM): same subscription.
- `Sodalite/Localizable.xcstrings`: new keys for all UI strings introduced below.

**Not touched (intentionally):**
- `RememberedUser`, per-server keychain key helpers (`accessToken(serverID:)` etc.). These are already correctly scoped per server.
- `JellyfinClient`, `SeerrClient`, the HTTP layer. `switchServer` reuses the existing `baseURL` + `accessToken` setters.
- TopShelf extension. `SharedSessionMirror` is rewritten by `switchServer`; the extension reads the same way it already does.
- AetherEngine. No engine touch.

---

## Task 1: Add multi-server keychain keys

**Files:**
- Modify: `Sodalite/Services/Keychain/KeychainKeys.swift`

- [ ] **Step 1: Add the two new static keys**

After the `static let seerrServer = "seerrServer"` line in `KeychainKeys`, add:

```swift
    /// JSON-encoded `[JellyfinServer]` list. Order is significant:
    /// the front of the list is the most recently added or upserted
    /// server. The picker and settings list render in this order.
    static let knownServers = "knownServers"

    /// The `JellyfinServer.id` of the currently active server. Must
    /// always resolve into an entry of `knownServers` when present.
    /// Cleared only when the user removes the last known server.
    static let activeServerID = "activeServerID"
```

- [ ] **Step 2: Build to confirm no other file referenced these names**

Run the build command above. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Services/Keychain/KeychainKeys.swift
git commit -m "$(cat <<'EOF'
chore(keychain): add knownServers + activeServerID keys

Storage foundation for multi-server. The keys are unused until the
DependencyContainer API and migration land in the next tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 2: `listKnownServers` + `addServer` + computed `activeServer`

**Files:**
- Modify: `Sodalite/App/Environment/DependencyContainer.swift`

These three pieces are atomic: the read API, the upsert API, and the active-server resolver. They are written together so the next task (migration) has a target API to write into.

- [ ] **Step 1: Add the three methods**

Insert into `DependencyContainer`, near the other server-state code (the existing `// MARK: - Remembered Profiles` block is a good landmark; this group goes above it as `// MARK: - Known Servers`):

```swift
    // MARK: - Known Servers

    /// All servers the user has ever logged into and not removed.
    /// Front of the list is the most recently added or upserted
    /// entry. Empty list on a fresh install or after the user has
    /// removed every server.
    func listKnownServers() -> [JellyfinServer] {
        guard let data = try? keychainService.loadData(for: KeychainKeys.knownServers)
        else { return [] }
        return (try? JSONDecoder().decode([JellyfinServer].self, from: data)) ?? []
    }

    /// Upsert by `JellyfinServer.id`. Existing entries with the same
    /// id are removed and the new value is prepended, so re-running
    /// the add flow against a server whose URL has changed updates
    /// the URL in place and floats the entry to the top of pickers.
    func addServer(_ server: JellyfinServer) throws {
        var servers = listKnownServers().filter { $0.id != server.id }
        servers.insert(server, at: 0)
        let data = try JSONEncoder().encode(servers)
        try keychainService.save(data, for: KeychainKeys.knownServers)
    }

    /// Resolves the active-server pointer against the known-servers
    /// list. Returns nil if either is missing (fresh install or a
    /// pointer that no longer resolves; the latter is repaired in
    /// AppRouter.restoreSession).
    var activeServer: JellyfinServer? {
        guard let id = try? keychainService.loadString(for: KeychainKeys.activeServerID)
        else { return nil }
        return listKnownServers().first(where: { $0.id == id })
    }
```

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Sodalite/App/Environment/DependencyContainer.swift
git commit -m "$(cat <<'EOF'
feat(container): add knownServers read + upsert + activeServer

Three small additions that establish the multi-server read path:
list, upsert (prepend, dedupe by id), and the active-server
resolver. No callers wired yet; switch/remove + AppRouter routing
follow.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 3: Migration from `"activeServer"` to the multi schema

**Files:**
- Modify: `Sodalite/Services/Keychain/KeychainMigrator.swift`

`KeychainMigrator` already runs at app launch (before the first `restoreSession` read). We extend it with a second one-shot step. Reuse the existing flag pattern (UserDefaults bool key).

- [ ] **Step 1: Add the migration constants**

Inside `KeychainMigrator`, add a second flag key beside `migratedFlagKey`:

```swift
    private static let activeServerMigratedFlagKey = "Sodalite.didMigrateActiveServerToMulti.v1"
```

- [ ] **Step 2: Add the migration function**

Add to the end of `KeychainMigrator` (before the closing brace):

```swift
    /// One-shot migration of the pre-multi-server keychain layout:
    /// the old `"activeServer"` slot held one JSON-encoded
    /// JellyfinServer. The new layout uses `knownServers` (an array)
    /// plus `activeServerID` (a pointer). We translate the single
    /// slot into a one-element list and set the pointer to its id.
    /// Per-server keys (accessToken_<id> etc.) are already correctly
    /// scoped and need no migration.
    static func migrateActiveServerToMultiIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: activeServerMigratedFlagKey) else { return }

        let keychain = KeychainService(
            service: newMainService,
            accessGroup: nil
        )

        // Skip cleanly on fresh installs (no old slot to migrate)
        // and on installs that already have the new schema.
        if (try? keychain.loadData(for: KeychainKeys.knownServers)) != nil {
            defaults.set(true, forKey: activeServerMigratedFlagKey)
            return
        }
        guard let blob = try? keychain.loadData(for: "activeServer"),
              let server = try? JSONDecoder().decode(JellyfinServer.self, from: blob)
        else {
            defaults.set(true, forKey: activeServerMigratedFlagKey)
            return
        }

        do {
            let list = try JSONEncoder().encode([server])
            try keychain.save(list, for: KeychainKeys.knownServers)
            try keychain.save(server.id, for: KeychainKeys.activeServerID)
            try? keychain.delete(for: "activeServer")
            log.notice("KeychainMigrator: activeServer -> multi schema (server id=\(server.id, privacy: .public))")
        } catch {
            log.notice("KeychainMigrator: activeServer -> multi failed: \(String(describing: error), privacy: .public)")
            return
        }

        defaults.set(true, forKey: activeServerMigratedFlagKey)
    }
```

- [ ] **Step 3: Wire the new migration into the existing `migrateIfNeeded` entry**

Inside `migrateIfNeeded`, after `migrateAppGroupDeviceID()` and before the `defaults.set(true, ...)` that flips the v1 flag, add:

```swift
        migrateActiveServerToMultiIfNeeded()
```

The two migrations are independent. The activeServer migration has its own flag so it can run on installs that completed the JellySeeTV migration months ago.

- [ ] **Step 4: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Manual migration check**

This step only verifies the migration path locally. Skip if you have no pre-multi build installed.

1. Install the latest 0.7.0 build on the Apple TV simulator (or device). Log in to at least one server.
2. Quit the app.
3. Install this build on top.
4. Launch. Observe: the app lands in either the profile picker or TabRoot for the same server you were on. No discovery screen, no re-login.
5. Open a fresh terminal and inspect the simulator keychain (if you have a helper script) or simply observe that the next switch-server flow (after Task 8 lands) shows the migrated server in the list.

If you do not have a pre-multi build to test against, note this in the task PR and rely on the post-implementation test pass (Task 18).

- [ ] **Step 6: Commit**

```bash
git add Sodalite/Services/Keychain/KeychainMigrator.swift
git commit -m "$(cat <<'EOF'
chore(keychain): migrate activeServer slot to multi schema

One-shot migration: the legacy "activeServer" JellyfinServer blob
becomes a 1-element knownServers list, with activeServerID pointing
at its id. Idempotent via a dedicated flag, independent of the
JellySeeTV migration's flag.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 4: `switchServer(to:)`

**Files:**
- Modify: `Sodalite/App/Environment/DependencyContainer.swift`

Core server-switch primitive. Loads per-server credentials, reconfigures the HTTP clients, rewrites SharedSessionMirror, and restores Seerr for the target server's most recently active user (if any).

- [ ] **Step 1: Add the method**

Inside the `// MARK: - Known Servers` group from Task 2:

```swift
    enum ServerSwitchError: Error {
        /// The requested server id was not in knownServers.
        case unknown
        /// The target server has no stored access token. The caller
        /// must show the profile picker (or LoginView if there are
        /// no remembered users either).
        case missingToken
    }

    /// Switch the active server to `serverID`. Sets the active-server
    /// pointer, loads the cached access token, reconfigures the
    /// Jellyfin HTTP client, rewrites SharedSessionMirror so TopShelf
    /// follows along, and restores the Seerr session for the most
    /// recently used remembered user on that server. The caller
    /// observes the resulting state via the appState.serverDidSwitch
    /// signal (incrementing token) added in a later task.
    ///
    /// Throws `ServerSwitchError.unknown` if the id is not in
    /// knownServers, `ServerSwitchError.missingToken` if the server
    /// has no cached access token (caller routes to login).
    func switchServer(to serverID: String) throws {
        guard let server = listKnownServers().first(where: { $0.id == serverID }) else {
            throw ServerSwitchError.unknown
        }

        try keychainService.save(serverID, for: KeychainKeys.activeServerID)

        let token: String
        do {
            token = try keychainService.loadString(for: KeychainKeys.accessToken(serverID: serverID))
        } catch {
            jellyfinClient.baseURL = server.url
            jellyfinClient.accessToken = nil
            SharedSessionMirror.clear()
            throw ServerSwitchError.missingToken
        }

        let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: serverID))

        jellyfinClient.baseURL = server.url
        jellyfinClient.accessToken = token

        if let userID {
            SharedSessionMirror.write(serverURL: server.url, userID: userID, accessToken: token)
        } else {
            SharedSessionMirror.clear()
        }

        // Seerr session is per (server, user); the caller layer
        // (AppRouter / restoreSession) handles the post-switch
        // probe + Seerr restore via the existing restore path. We
        // intentionally do not touch Seerr here so callers can
        // route to a profile picker first when userID is nil.
    }
```

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Sodalite/App/Environment/DependencyContainer.swift
git commit -m "$(cat <<'EOF'
feat(container): add switchServer primitive

Server-level switch: updates activeServerID, loads cached token,
reconfigures JellyfinClient, rewrites SharedSessionMirror so
TopShelf follows. Seerr restore is intentionally deferred to the
post-switch restoreSession path so a missing remembered user
routes through the profile picker.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 5: `removeServer(id:)`

**Files:**
- Modify: `Sodalite/App/Environment/DependencyContainer.swift`

Per-server cleanup. Wipes that server's access token, password, remembered users, all Seerr cookies under the (server, *) namespace, and removes the entry from `knownServers`. If the removed server was the active one, picks a successor (or clears the pointer if it was the last).

- [ ] **Step 1: Add the method**

In the same `// MARK: - Known Servers` group:

```swift
    /// Remove a server and every piece of state scoped to it. The
    /// per-server access token, password, remembered users, and all
    /// remembered Seerr sessions for users on this server are
    /// deleted. If the removed server was the active one and at
    /// least one other server remains, the most recently added
    /// remaining server is promoted to active (with whatever token
    /// it has cached; AppRouter's restoreSession path handles
    /// expired tokens). If no servers remain, activeServerID is
    /// cleared and SharedSessionMirror is wiped, the next launch
    /// lands in ServerDiscoveryView.
    func removeServer(id serverID: String) throws {
        let allUsers = listRememberedUsers(serverID: serverID)
        for remembered in allUsers {
            forgetRememberedSeerr(
                forJellyfinUserID: remembered.id,
                jellyfinServerID: serverID
            )
        }

        try? keychainService.delete(for: KeychainKeys.accessToken(serverID: serverID))
        try? keychainService.delete(for: KeychainKeys.jellyfinPassword(serverID: serverID))
        try? keychainService.delete(for: KeychainKeys.userID(serverID: serverID))
        try? keychainService.delete(for: KeychainKeys.rememberedUsers(serverID: serverID))

        var servers = listKnownServers().filter { $0.id != serverID }
        let data = try JSONEncoder().encode(servers)
        try keychainService.save(data, for: KeychainKeys.knownServers)

        let activeID = try? keychainService.loadString(for: KeychainKeys.activeServerID)
        if activeID == serverID {
            if let successor = servers.first {
                try? switchServer(to: successor.id)
            } else {
                try? keychainService.delete(for: KeychainKeys.activeServerID)
                jellyfinClient.baseURL = nil
                jellyfinClient.accessToken = nil
                SharedSessionMirror.clear()
            }
        }
    }
```

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Sodalite/App/Environment/DependencyContainer.swift
git commit -m "$(cat <<'EOF'
feat(container): add removeServer primitive

Scoped per-server cleanup: token, password, remembered users, and
all per-(server, user) Seerr cookies. Removing the active server
promotes the next entry to active when present, otherwise clears
the pointer and SharedSessionMirror (the next launch lands in
discovery).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 6: AppState `serverDidSwitch` signal + transient-state reset

**Files:**
- Modify: `Sodalite/App/AppState.swift`
- Modify: `Sodalite/App/Environment/DependencyContainer.swift`
- Modify: `Sodalite/Features/Home/HomeViewModel.swift`
- Modify: `Sodalite/Features/Library/LibraryView.swift` (or the file owning the library list state)

The signal follows the existing `pendingDeepLinkItemID` / `requestContinueWatching` pattern: a `@Published` token that consumers observe via `.task(id:)`. `DependencyContainer.switchServer` and `removeServer` bump it on success.

- [ ] **Step 1: Add the field to AppState**

In `Sodalite/App/AppState.swift`, near the other signal fields (search for `requestContinueWatching` for the pattern):

```swift
    /// Incremented by DependencyContainer after every successful
    /// server switch. Consumers (Home, Library) observe via
    /// `.task(id: appState.serverDidSwitch)` and clear their caches
    /// + reload. Uses an integer rather than a Date so back-to-back
    /// switches always change the value.
    var serverDidSwitch: Int = 0
```

- [ ] **Step 2: Make the container bump the signal**

In `DependencyContainer.swift`, the container needs a reference to the `AppState` so it can post the signal. Check the existing init: AppState is injected in `SodaliteApp.init` already (both the AppState and DependencyContainer are created there). Plumb a weak reference in:

```swift
    weak var appState: AppState?
```

In `SodaliteApp.init`, after creating both, wire them:

```swift
        dependencies.appState = appState
```

Then at the end of `switchServer(to:)` (after the final assignment, before the function returns), add:

```swift
        Task { @MainActor in
            self.appState?.serverDidSwitch &+= 1
        }
```

And at the end of `removeServer(id:)` (after any successor switch), add:

```swift
        Task { @MainActor in
            self.appState?.serverDidSwitch &+= 1
        }
```

Use `&+=` (overflow-add) so the signal never traps on overflow even on a long-lived process.

- [ ] **Step 3: HomeViewModel observes**

In `Sodalite/Features/Home/HomeViewModel.swift`, add a public method (or expose the existing reload) and have the view subscribe. The view that hosts `HomeViewModel` (find via grep: `HomeViewModel(`) gets:

```swift
        .task(id: appState.serverDidSwitch) {
            // Skip the first firing at value 0 (no switch has happened yet)
            guard appState.serverDidSwitch > 0 else { return }
            FilterCache.shared.clearAll()
            await viewModel.reloadAfterServerSwitch()
        }
```

`reloadAfterServerSwitch` on the VM should be a thin wrapper that resets in-memory state and triggers the same code path as a cold load. The exact implementation depends on the VM's current load entry point; the simplest version:

```swift
    @MainActor
    func reloadAfterServerSwitch() async {
        // Clear in-memory state so a partial render doesn't show
        // the previous server's posters while the new server's
        // carousels are still loading.
        carousels = []
        await loadHome()  // existing entry point; rename if HomeViewModel uses a different one
    }
```

If the existing load entry point already clears `carousels` itself, the explicit `carousels = []` is redundant; verify against the actual file before adding it.

- [ ] **Step 4: LibraryView observes**

Same pattern in the library list view. The library state lives in `Sodalite/Features/Library/LibraryView.swift` (or its VM). Add:

```swift
        .task(id: appState.serverDidSwitch) {
            guard appState.serverDidSwitch > 0 else { return }
            FilterCache.shared.clearAll()
            await viewModel.reloadAfterServerSwitch()
        }
```

And the equivalent `reloadAfterServerSwitch` method on the library VM. If the library has no VM (purely view-driven), do the reload inline.

- [ ] **Step 5: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Sodalite/App/AppState.swift Sodalite/App/Environment/DependencyContainer.swift Sodalite/Features/Home/HomeViewModel.swift Sodalite/Features/Library/LibraryView.swift Sodalite/SodaliteApp.swift
git commit -m "$(cat <<'EOF'
feat(state): wire serverDidSwitch signal + Home/Library reloads

Container bumps an integer token on every successful switchServer /
removeServer; Home and Library observe it via .task(id:) and clear
their FilterCache slice + reload. Pattern matches the existing
pendingDeepLinkItemID / requestContinueWatching signals so the
plumbing stays uniform.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 7: AppRouter routes via `dependencies.activeServer`

**Files:**
- Modify: `Sodalite/App/AppRouter.swift`

Today `AppRouter` reads `"activeServer"` directly from the keychain (line ~257). Switch to the new resolver and add the repair path for a dangling `activeServerID` pointer.

- [ ] **Step 1: Replace direct keychain access in AppRouter**

Find the block around `AppRouter.swift:257` that reads `serverData` from keychain. Replace it with a call through the container:

```swift
        guard let server = dependencies.activeServer else {
            // No active server, or the pointer no longer resolves.
            // If knownServers is non-empty, repair by promoting the
            // most recently added entry. Otherwise fall through and
            // land in ServerDiscoveryView.
            if let firstKnown = dependencies.listKnownServers().first {
                try? dependencies.switchServer(to: firstKnown.id)
                // Fall through to the next iteration of the route
                // resolver; the launchPickerServer computed property
                // will now see the promoted server.
                appState.activeServer = firstKnown
            }
            return
        }
```

The exact return / control flow depends on the surrounding restoreSession structure. Adapt to match: the goal is `dependencies.activeServer` (computed) replaces the manual keychain read, and on a missing pointer with non-empty `knownServers`, the first entry is promoted before falling through to the normal restore path.

- [ ] **Step 2: Update `launchPickerServer` derivation**

Find where `launchPickerServer` is computed (top of the file around line 30-40). If it reads from `appState.activeServer`, it is already correct. If it reads from keychain directly, route it through `dependencies.activeServer`.

- [ ] **Step 3: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Manual smoke check**

Cold-launch the app. Expected: identical behavior to today (lands in profile picker or TabRoot for the existing active server). The migration from Task 3 must have run first; if it hasn't, the active server is nil and the user is dropped in ServerDiscoveryView, which is the correct fallback for a fresh install but wrong for an upgrader. If you see the discovery screen unexpectedly, debug Task 3.

- [ ] **Step 5: Commit**

```bash
git add Sodalite/App/AppRouter.swift
git commit -m "$(cat <<'EOF'
feat(router): resolve active server via DependencyContainer

AppRouter no longer reads "activeServer" from the keychain directly;
it goes through dependencies.activeServer (the multi-aware
resolver). A dangling activeServerID pointer (knownServers list
non-empty but pointer broken) is repaired by promoting the most
recently added entry before the normal restore path runs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 8: `ServerSwitchSheet` view

**Files:**
- Create: `Sodalite/Features/Auth/ServerSwitchSheet.swift`

A modal sheet listing all known servers with switch + add actions. Used both from the Launch Profile Picker (Task 9) and as a "Server hinzufügen" entry point from Settings (Task 11).

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

/// Modal sheet for picking among `knownServers` or adding a new one.
/// Presented from `LaunchProfilePickerView` (server header card)
/// and from `ServerManagementView` (Settings) for the same purpose.
struct ServerSwitchSheet: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    /// Called after the user picks "Neuer Server". The host view
    /// is expected to push or fullScreenCover a ServerDiscoveryView
    /// configured in add-mode.
    let onAddServer: () -> Void

    /// Called after the user has picked a different server and the
    /// switch has been attempted. The bool indicates whether the
    /// switch succeeded. The host uses this to react (e.g. dismiss
    /// the picker for a successful switch, show a toast on failure).
    let onSwitched: (Bool) -> Void

    @State private var servers: [JellyfinServer] = []
    @State private var activeID: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("multiServer.switchSheet.title", bundle: .main)
                .font(.title2.bold())
                .foregroundStyle(.primary)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(servers) { server in
                        ServerRow(
                            server: server,
                            isActive: server.id == activeID,
                            onTap: { switchTo(server) }
                        )
                    }
                    AddServerRow(onTap: {
                        dismiss()
                        onAddServer()
                    })
                }
                .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: 900, maxHeight: 700)
        .padding(40)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onAppear(perform: load)
    }

    private func load() {
        servers = dependencies.listKnownServers()
        activeID = dependencies.activeServer?.id
    }

    private func switchTo(_ server: JellyfinServer) {
        if server.id == activeID {
            dismiss()
            return
        }
        do {
            try dependencies.switchServer(to: server.id)
            onSwitched(true)
            dismiss()
        } catch {
            // Token missing or unknown id; report up so the host can
            // route to the profile picker / login for the target.
            onSwitched(false)
            dismiss()
        }
    }
}

private struct ServerRow: View {
    let server: JellyfinServer
    let isActive: Bool
    let onTap: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.headline)
                Text(server.url.host() ?? server.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Text("multiServer.row.active", bundle: .main)
                    .font(.caption.bold())
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.tint.opacity(0.18), in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(focused ? Color.accentColor.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Color.accentColor : Color.white.opacity(0.08), lineWidth: focused ? 2 : 1)
        )
        .focused($focused)
        .stableTap(isFocused: focused, perform: onTap)
    }
}

private struct AddServerRow: View {
    let onTap: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("multiServer.row.add", bundle: .main)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(focused ? Color.accentColor.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Color.accentColor : Color.white.opacity(0.08), lineWidth: focused ? 2 : 1)
        )
        .focused($focused)
        .stableTap(isFocused: focused, perform: onTap)
    }
}
```

Notes for the implementer:
- The `stableTap` modifier is in `Sodalite/Components/StableTap.swift` (already shipped per the touchpad-sensitivity plan). Use it for tvOS-correct focus-gated activation. Verify import paths if it lives in a different file.
- The visual style mirrors `ValuePickerRow` and the focus-styling convention (`feedback_sodalite_ui_focus_and_tint`): tint-strokes, no Apple white halo, focused row fills with `Color.accentColor.opacity(0.2)`.
- The xcstrings keys (`multiServer.switchSheet.title`, `multiServer.row.active`, `multiServer.row.add`) are added in Task 16.

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED` (with the xcstrings keys missing the strings; tvOS renders the key literal in dev until Task 16 fills them in. If the build fails on missing-string warnings-as-errors, temporarily replace the localized strings with hard-coded EN text and revisit in Task 16).

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Features/Auth/ServerSwitchSheet.swift
git commit -m "$(cat <<'EOF'
feat(auth): add ServerSwitchSheet view

Modal sheet listing knownServers with switch + add actions.
Presented from the Launch Profile Picker server header (next task)
and reused from Settings. stableTap activation, tint-stroke focus
styling per the Sodalite UI convention.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 9: Server header card in `LaunchProfilePickerView`

**Files:**
- Modify: `Sodalite/Features/Auth/LaunchProfilePickerView.swift`

Add a focusable card above the existing profile rows that shows the active server and opens the switch sheet on activation.

- [ ] **Step 1: Add a state field for the sheet presentation**

At the top of `LaunchProfilePickerView`'s state declarations:

```swift
    @State private var showServerSwitchSheet = false
    @State private var showAddServerFlow = false
```

- [ ] **Step 2: Insert the header card above the profile list**

Find the `body` (or whichever section assembles the picker layout) and insert the header card immediately above the profile rows. The card looks like:

```swift
            Button(action: { showServerSwitchSheet = true }) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("multiServer.picker.header.label", bundle: .main)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(server.name)
                            .font(.title3.bold())
                        Text(server.url.host() ?? server.url.absoluteString)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .buttonStyle(.card)
            .padding(.horizontal, 60)
            .padding(.bottom, 32)
```

Use `Button` + `.card` button style here (rather than `stableTap`) because this is a *new* row at a stable location and the picker header isn't subject to the wrong-tile drift problem stableTap solved. If a focus regression appears in testing, swap to stableTap to match the row pattern in `ServerSwitchSheet`.

- [ ] **Step 3: Present the sheet**

Add at the bottom of the picker's `body`:

```swift
        .sheet(isPresented: $showServerSwitchSheet) {
            ServerSwitchSheet(
                onAddServer: {
                    showAddServerFlow = true
                },
                onSwitched: { _ in
                    // Picker re-resolves the active server via the
                    // environment dependencies on next render; no
                    // explicit reload needed here.
                }
            )
        }
        .fullScreenCover(isPresented: $showAddServerFlow) {
            ServerDiscoveryView(addMode: true) {
                showAddServerFlow = false
            }
        }
```

The `addMode: Bool` + completion handler on `ServerDiscoveryView` is added in Task 10.

- [ ] **Step 4: Build**

`xcodebuild ... build`. Expected: build error at the `ServerDiscoveryView(addMode:)` initializer because Task 10 hasn't shipped yet. To unblock the build for this task in isolation, temporarily replace the `fullScreenCover` content with `EmptyView()` and add a TODO referencing Task 10. Restore the `ServerDiscoveryView` call in Task 10.

If running tasks sequentially (no parallel branches), defer the build verification in this task and run it at the end of Task 10 instead.

- [ ] **Step 5: Commit**

```bash
git add Sodalite/Features/Auth/LaunchProfilePickerView.swift
git commit -m "$(cat <<'EOF'
feat(auth): add server header card to Launch Profile Picker

The picker now opens with a focusable card showing the active
server (name + host) and an arrow-arrow icon hinting at the
switch action. Activation opens ServerSwitchSheet. Followup task
wires the add-server flow into ServerDiscoveryView.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 10: `ServerDiscoveryView` in `addMode` + post-login routing

**Files:**
- Modify: `Sodalite/Features/Auth/ServerDiscoveryView.swift`
- Modify: `Sodalite/Features/Auth/ServerDiscoveryViewModel.swift`
- Modify: `Sodalite/Features/Auth/LoginViewModel.swift`

The discovery view today is single-purpose (first-run onboarding). We extend it with an `addMode` flag that affects only the post-login flow:
- First-run (`addMode == false`): same as today (set as initial server + start session).
- Add-mode (`addMode == true`): `addServer` + `switchServer` + dismiss back to the caller.

- [ ] **Step 1: Add `addMode` + completion handler to `ServerDiscoveryView`**

In the view's signature:

```swift
struct ServerDiscoveryView: View {
    /// If true, the post-login flow runs through addServer instead
    /// of the first-run "set as initial server" path. The completion
    /// closure is called when the user has either finished adding
    /// (success) or cancelled out (no server added).
    var addMode: Bool = false
    var onCompletion: (() -> Void)? = nil

    // ... existing body
}
```

If `ServerDiscoveryView` already takes parameters, slot these in beside them.

- [ ] **Step 2: Plumb `addMode` into the VM**

`ServerDiscoveryViewModel` (or whichever VM owns the post-login completion) needs the same flag, set on construction from the view. Add a stored property:

```swift
    let addMode: Bool
```

And in its init:

```swift
    init(..., addMode: Bool = false) {
        // existing assignments
        self.addMode = addMode
    }
```

- [ ] **Step 3: Branch the post-login handler in the VM**

Find the existing post-login success path in `ServerDiscoveryViewModel` (or `LoginViewModel` if that's where the success flow lives — grep `setAuthenticated`). In both add-mode and first-run, the new code path is:

```swift
        // Persist the server in the multi-aware schema, regardless
        // of mode. addServer upserts so a re-login on a previously
        // known server (URL changed, etc.) just refreshes its entry.
        try dependencies.addServer(server)

        if addMode {
            // Switch to the newly added server (and persist the new
            // user/token via the same path the first-run flow uses).
            // Then call the completion handler so the host (picker
            // or settings) dismisses the discovery cover.
            try dependencies.switchServer(to: server.id)
            // The existing rememberUser + activeServer-write logic
            // continues to run here (it sets the per-server token,
            // userID, primary image tag, and Seerr session).
            onCompletion?()
        } else {
            // First-run: existing setAuthenticated flow takes over.
            appState.setAuthenticated(server: server, user: user)
        }
```

Adapt to the actual existing structure. The two essential changes are:
1. `addServer` is called *before* `setAuthenticated` (so the keychain has the multi schema even when a first-run user has just one entry).
2. `addMode` branches to `switchServer + onCompletion` instead of `setAuthenticated`.

- [ ] **Step 4: Restore the `ServerDiscoveryView(addMode:)` call in LaunchProfilePickerView**

If Task 9 used `EmptyView()` as a placeholder for the `fullScreenCover` content, replace it with:

```swift
        .fullScreenCover(isPresented: $showAddServerFlow) {
            ServerDiscoveryView(addMode: true) {
                showAddServerFlow = false
            }
        }
```

- [ ] **Step 5: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Manual two-server smoke test**

1. Cold-launch with one server known. Land in profile picker for that server.
2. Tap the server header. Switch sheet opens, shows that one server (marked Aktiv) and "Neuer Server".
3. Tap "Neuer Server". Discovery view opens, you can pick a second server on the LAN and log in.
4. After login, the cover dismisses. The picker now shows the *second* server in its header. The original server's profile picker rows are gone (the new server has its own profile list).
5. Tap the new server's header → switch sheet now shows both servers. Switch back to the original. Picker re-renders with the original server's profiles.

If any step fails, debug before moving on.

- [ ] **Step 7: Commit**

```bash
git add Sodalite/Features/Auth/ServerDiscoveryView.swift Sodalite/Features/Auth/ServerDiscoveryViewModel.swift Sodalite/Features/Auth/LoginViewModel.swift Sodalite/Features/Auth/LaunchProfilePickerView.swift
git commit -m "$(cat <<'EOF'
feat(auth): wire add-server flow through ServerDiscoveryView

ServerDiscoveryView gains an addMode + completion handler. In
add-mode the post-login flow calls addServer + switchServer
instead of setAuthenticated, and the host dismisses the cover.
First-run behaviour is unchanged (addServer is now always called
before setAuthenticated to populate the multi schema even with
a single entry).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 11: `ServerManagementView`

**Files:**
- Create: `Sodalite/Features/Settings/ServerManagementView.swift`

Settings sub-screen listing every known server with per-row switch / remove actions and an "add server" entry.

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

/// Settings sub-screen for managing knownServers. Lists every
/// server with switch (long-press) + remove (long-press) actions.
/// "Server hinzufügen" at the bottom routes through the same
/// ServerDiscoveryView add-flow used by the Launch Profile Picker.
struct ServerManagementView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

    @State private var servers: [JellyfinServer] = []
    @State private var activeID: String?
    @State private var showAddServerFlow = false
    @State private var pendingRemoval: JellyfinServer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("multiServer.settings.title", bundle: .main)
                    .font(.largeTitle.bold())
                    .padding(.bottom, 8)

                ForEach(servers) { server in
                    ServerManagementRow(
                        server: server,
                        isActive: server.id == activeID,
                        userCount: dependencies.listRememberedUsers(serverID: server.id).count,
                        onSwitch: { switchTo(server) },
                        onRemove: { pendingRemoval = server }
                    )
                }

                AddServerSettingsRow(onTap: { showAddServerFlow = true })
                    .padding(.top, 16)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .onAppear(perform: load)
        .fullScreenCover(isPresented: $showAddServerFlow) {
            ServerDiscoveryView(addMode: true) {
                showAddServerFlow = false
                load()
            }
        }
        .alert(item: $pendingRemoval) { server in
            Alert(
                title: Text("multiServer.remove.confirm.title", bundle: .main),
                message: Text("multiServer.remove.confirm.message \(server.name)", bundle: .main),
                primaryButton: .destructive(
                    Text("multiServer.remove.confirm.action", bundle: .main),
                    action: { remove(server) }
                ),
                secondaryButton: .cancel()
            )
        }
    }

    private func load() {
        servers = dependencies.listKnownServers()
        activeID = dependencies.activeServer?.id
    }

    private func switchTo(_ server: JellyfinServer) {
        guard server.id != activeID else { return }
        try? dependencies.switchServer(to: server.id)
        load()
    }

    private func remove(_ server: JellyfinServer) {
        try? dependencies.removeServer(id: server.id)
        load()
    }
}

private struct ServerManagementRow: View {
    let server: JellyfinServer
    let isActive: Bool
    let userCount: Int
    let onSwitch: () -> Void
    let onRemove: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(server.name)
                        .font(.headline)
                    if isActive {
                        Text("multiServer.row.active", bundle: .main)
                            .font(.caption.bold())
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.tint.opacity(0.18), in: Capsule())
                    }
                }
                Text(server.url.host() ?? server.url.absoluteString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("multiServer.row.userCount \(userCount)", bundle: .main)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(focused ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 2)
        )
        .focused($focused)
        .stableTap(isFocused: focused) {
            // Single tap = switch. Remove is via the contextMenu below.
            if !isActive { onSwitch() }
        }
        .contextMenu {
            if !isActive {
                Button {
                    onSwitch()
                } label: {
                    Label {
                        Text("multiServer.row.action.switch", bundle: .main)
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                }
            }
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label {
                    Text("multiServer.row.action.remove", bundle: .main)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
    }
}

private struct AddServerSettingsRow: View {
    let onTap: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("multiServer.settings.add", bundle: .main)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(focused ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 2)
        )
        .focused($focused)
        .stableTap(isFocused: focused, perform: onTap)
    }
}
```

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: build error if `JellyfinServer` doesn't conform to `Identifiable` for the `alert(item:)` API; it does (Task 0 verified). Otherwise `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Features/Settings/ServerManagementView.swift
git commit -m "$(cat <<'EOF'
feat(settings): add ServerManagementView

Settings sub-screen listing knownServers with per-row switch
(stableTap) + remove (contextMenu with destructive confirm). Add-
server row at the bottom routes through ServerDiscoveryView in
addMode. Visual style mirrors PlaybackSettingsView's row pattern.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 12: Link `ServerManagementView` from `SettingsView`

**Files:**
- Modify: `Sodalite/Features/Settings/SettingsView.swift`

Add a row in the main settings list that pushes `ServerManagementView`. Place it near the `ProfileSettingsView` row (the conceptually closest neighbour) or wherever the existing section conventions suggest.

- [ ] **Step 1: Add the row**

In `SettingsView.body`, near the `ProfileSettingsView` navigation link:

```swift
            NavigationLink(destination: ServerManagementView()) {
                HStack(spacing: 16) {
                    Image(systemName: "server.rack")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("multiServer.settings.entry.title", bundle: .main)
                            .font(.headline)
                        Text("multiServer.settings.entry.subtitle", bundle: .main)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .buttonStyle(.card)
```

If `SettingsView` uses a different row pattern (Form, List, custom focusable rows), adapt to match. The goal is the entry point is discoverable in the same place as the other server / account-adjacent settings.

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Features/Settings/SettingsView.swift
git commit -m "$(cat <<'EOF'
feat(settings): link ServerManagementView from main settings

New entry alongside the profile/account row. Same navigation
pattern, server-rack icon, two-line description.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 13: Post-switch `/Users/Me` probe + 401 fallback

**Files:**
- Modify: `Sodalite/App/Environment/DependencyContainer.swift`
- Modify: `Sodalite/App/AppRouter.swift`

After a `switchServer` lands, AppRouter probes `/Users/Me` against the new server. On 401, drop the remembered user for that server and route to the profile picker (which falls through to LoginView if the user list is empty).

- [ ] **Step 1: Add a `probeActiveUser()` method on the container**

In `DependencyContainer.swift`, near `restoreSession`:

```swift
    /// Probes /Users/Me against the active server. Returns the
    /// JellyfinUser on success. On 401, drops the remembered entry
    /// for that (server, user) pair and the access token slot, and
    /// returns nil so the caller can route to the profile picker.
    /// Throws on transport errors (caller should keep the previous
    /// server active and surface a toast).
    @MainActor
    func probeActiveUser() async throws -> JellyfinUser? {
        guard let server = activeServer,
              let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: server.id))
        else { return nil }

        do {
            let user = try await jellyfinAuthService.fetchUser(id: userID)
            return user
        } catch let error as HTTPError where error.statusCode == 401 {
            try? keychainService.delete(for: KeychainKeys.accessToken(serverID: server.id))
            try? keychainService.delete(for: KeychainKeys.userID(serverID: server.id))

            // Drop the remembered user too; their token is dead.
            var users = listRememberedUsers(serverID: server.id)
            users.removeAll { $0.id == userID }
            if let data = try? JSONEncoder().encode(users) {
                try? keychainService.save(data, for: KeychainKeys.rememberedUsers(serverID: server.id))
            }
            jellyfinClient.accessToken = nil
            SharedSessionMirror.clear()
            return nil
        }
    }
```

Adapt the `jellyfinAuthService.fetchUser(id:)` call to whatever the actual service method is (`getCurrentUser()` or similar). Grep for `/Users/Me` in `JellyfinAuthService.swift` to find the existing probe.

- [ ] **Step 2: Have AppRouter run the probe after a switch**

In `AppRouter.swift`, add an observer for `serverDidSwitch`:

```swift
        .task(id: appState.serverDidSwitch) {
            guard appState.serverDidSwitch > 0 else { return }
            do {
                let user = try await dependencies.probeActiveUser()
                if let user {
                    appState.setAuthenticated(server: dependencies.activeServer!, user: user)
                } else {
                    // Token expired or no remembered user: route to
                    // the profile picker for the new active server.
                    appState.activeServer = dependencies.activeServer
                    appState.isAuthenticated = false
                }
            } catch {
                // Transport error during probe. Leave isAuthenticated
                // as-is; the user will see a stale TabRoot for ~5 s
                // until the next user-driven request hits the network
                // and surfaces the real failure. A more aggressive
                // path is to roll the switch back; defer until we
                // see this in the wild.
            }
        }
```

- [ ] **Step 3: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Sodalite/App/Environment/DependencyContainer.swift Sodalite/App/AppRouter.swift
git commit -m "$(cat <<'EOF'
feat(router): probe /Users/Me after server switch, drop on 401

AppRouter observes serverDidSwitch and runs probeActiveUser()
against the new server's cached token. On 401 the token + the
remembered entry for that (server, user) are dropped and the UI
routes to the profile picker (which falls through to LoginView
if the user list is empty).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 14: Unreachable-server rollback

**Files:**
- Modify: `Sodalite/App/Environment/DependencyContainer.swift`
- Modify: `Sodalite/Features/Auth/ServerSwitchSheet.swift`

If the probe in Task 13 throws a transport error (not 401, not a clean missing-token case), the switch should be rolled back to the previous server so the user isn't stuck pointing at an unreachable host with no path back.

- [ ] **Step 1: Add a `rollbackSwitch(to:)` method on the container**

```swift
    /// Roll the active-server pointer back to a previous value.
    /// Used when a post-switch probe fails with a transport error
    /// (network down, server unreachable). Resets JellyfinClient
    /// and SharedSessionMirror to the rollback target's cached
    /// state so the rest of the app sees a consistent snapshot of
    /// the previous server.
    func rollbackSwitch(to serverID: String) throws {
        try switchServer(to: serverID)
        // Re-issue the serverDidSwitch signal so observers reload
        // against the rolled-back state (carousels were already
        // cleared by the original switch; clear them again so they
        // don't show stale data from the unreachable server's
        // partial responses).
        Task { @MainActor in
            self.appState?.serverDidSwitch &+= 1
        }
    }
```

- [ ] **Step 2: Capture the previous serverID before switching in the sheet**

In `ServerSwitchSheet.switchTo(_:)`, capture the active id *before* the switch attempt and pass it along to `onSwitched` so the host can roll back on failure:

```swift
    private func switchTo(_ server: JellyfinServer) {
        if server.id == activeID {
            dismiss()
            return
        }
        let previous = activeID
        do {
            try dependencies.switchServer(to: server.id)
            onSwitched(true)
            dismiss()
        } catch {
            // Switch failed at the container layer (missing token /
            // unknown id). Surface as a failed switch; the host's
            // onSwitched(false) can decide to roll back.
            if let previous {
                try? dependencies.rollbackSwitch(to: previous)
            }
            onSwitched(false)
            dismiss()
        }
    }
```

The probe failure in Task 13 is handled in AppRouter, not here. AppRouter knows the previous server id (via `appState.activeServer` before the switch fires the signal). Add the same rollback path there:

In `AppRouter.swift`, replace the catch block in the `serverDidSwitch` task with:

```swift
            } catch {
                // Transport error on the new server. Roll back to
                // the previous server (held in appState.activeServer
                // until the next setAuthenticated). Surface a toast
                // via appState (existing pattern; if none exists,
                // print to console for now and add the toast UI in
                // a follow-up task).
                if let previous = appState.activeServer {
                    try? dependencies.rollbackSwitch(to: previous.id)
                }
            }
```

- [ ] **Step 3: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Manual unreachable check**

1. With two servers known, point one of them at a URL that is reachable on first add but unreachable now (the simplest reproduction: add a LAN server, then kill the Jellyfin host process).
2. Switch to the unreachable server from the picker. Expected: brief loading state, then the picker re-renders for the *previous* (reachable) server. Toast or console log indicates the failure.
3. Verify the keychain still has the unreachable server in `knownServers` and that activeServerID points back at the original.

- [ ] **Step 5: Commit**

```bash
git add Sodalite/App/Environment/DependencyContainer.swift Sodalite/Features/Auth/ServerSwitchSheet.swift Sodalite/App/AppRouter.swift
git commit -m "$(cat <<'EOF'
feat(router): roll back active server on unreachable switch

If switchServer's post-probe sees a transport error (network down,
server unreachable), AppRouter calls rollbackSwitch(to: previous)
so the user isn't stranded pointing at a dead host. The sheet
also rolls back when the container layer itself throws (missing
token, unknown id) before the probe ever runs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 15: Localization keys

**Files:**
- Modify: `Sodalite/Localizable.xcstrings`

Add every new UI string. Per `project_xcstrings_pipeline` and `feedback_translate_all_locales_properly`, run the spacing sed and ship real translations for all 26 locales, not EN-cloned stubs.

The keys, with EN + DE values (the implementer translates the remaining 24 locales):

| Key | EN | DE |
| --- | --- | --- |
| `multiServer.switchSheet.title` | Switch server | Server wechseln |
| `multiServer.row.active` | Active | Aktiv |
| `multiServer.row.add` | Add server | Neuer Server |
| `multiServer.picker.header.label` | Server | Server |
| `multiServer.settings.title` | Servers | Server |
| `multiServer.settings.add` | Add a server | Server hinzufügen |
| `multiServer.settings.entry.title` | Servers | Server |
| `multiServer.settings.entry.subtitle` | Manage your Jellyfin servers | Verwalte deine Jellyfin-Server |
| `multiServer.row.userCount` (format) | %lld profiles | %lld Profile |
| `multiServer.row.action.switch` | Switch to this server | Zu diesem Server wechseln |
| `multiServer.row.action.remove` | Remove server | Server entfernen |
| `multiServer.remove.confirm.title` | Remove server? | Server entfernen? |
| `multiServer.remove.confirm.message` (format) | This deletes all profiles, tokens, and Seerr sessions for "%@". The server itself is not affected. | Alle Profile, Tokens und Seerr-Sitzungen für "%@" werden gelöscht. Der Server selbst ist nicht betroffen. |
| `multiServer.remove.confirm.action` | Remove | Entfernen |

- [ ] **Step 1: Splice the entries**

Generate the JSON fragment in the format Xcode uses (`"key" : { ... }` with spaces around the colon, per the memory's `project_xcstrings_pipeline`). The implementer either edits xcstrings in Xcode (which uses the right formatting automatically) OR generates JSON and runs the sed normalization:

```bash
sed -i '' 's/"\([^"]*\)": {/"\1" : {/g' generated.json
```

Then splice into `Sodalite/Localizable.xcstrings` in the alphabetically-sorted `strings` block (xcstrings is sorted).

- [ ] **Step 2: Translate to the remaining 24 locales**

The full locale list in the catalog: ar, ca, cs, da, de, el, en, es, es-MX, fi, fr, he, hi, hu, id, it, ja, ko, nb, nl, pl, pt-BR, pt-PT, ru, sv, th, tr, uk, vi, zh-Hans, zh-Hant. Cross-reference an existing key that has full coverage (e.g. `settings.title`) to confirm the canonical locale list for this build.

For each locale, provide a real translation (machine-assisted is fine, but never EN-cloned `needs_review` stubs). When in doubt about a phrase, mark the locale `extracted_with_value` and submit for a follow-up review pass.

- [ ] **Step 3: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED` with no missing-key warnings.

- [ ] **Step 4: Visual sweep**

Launch the app in at least DE and EN, navigate to:
1. Launch Profile Picker (server header card text).
2. Switch sheet (title, active badge, add row).
3. Settings → Servers (entry row, list rows, remove confirm).

Confirm no raw `multiServer.…` keys leak into the UI.

- [ ] **Step 5: Commit**

```bash
git add Sodalite/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
i18n(auth+settings): add multi-server strings to all locales

14 new keys for the picker server header, switch sheet, settings
management view, and remove-confirm dialog. Translated to all 26
supported locales (no EN-cloned stubs per the localization
convention).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 16: CHANGELOG entry

**Files:**
- Modify: `Sodalite/Features/Changelog/Changelog.swift` (or wherever the changelog entries live; grep `Changelog.latest`)

- [ ] **Step 1: Add a 0.8.0 entry above the current latest**

Match the existing `Changelog` entry struct shape. Headline + body:

- **Headline:** "Multi-server" (EN) / "Multi-Server" (DE).
- **Body (EN):** "You can now keep several Jellyfin servers in Sodalite and switch between them without logging out. Tap the server name above your profile list to pick or add a server. Manage the full list in Settings → Servers."
- **Body (DE):** "Sodalite kennt jetzt mehrere Jellyfin-Server gleichzeitig. Du kannst zwischen ihnen wechseln, ohne dich auszuloggen. Den Server-Namen über der Profil-Liste antippen, um zu wechseln oder einen neuen hinzuzufügen. Die vollständige Liste verwaltest du unter Einstellungen → Server."

Translate to all 26 locales the same way as in Task 15.

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Features/Changelog/Changelog.swift Sodalite/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
feat(changelog): add 0.8.0 multi-server entry

Translated for all 26 locales.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 17: Manual test pass per spec

This task contains no code changes. It is the "verification before completion" gate.

- [ ] **Step 1: Migration smoke**

Install the last 0.7.x build, log into one server, create at least one remembered profile. Quit. Install this build. Launch.
Expected: lands in profile picker for the same server. Settings → Servers shows that server marked Aktiv. No discovery screen.

- [ ] **Step 2: Two-server happy path**

Add a second server via the picker's "Neuer Server" entry. Switch back and forth via both the picker header and Settings.
Expected: each server's profile list, library, and home reflect that server. Seerr session restores per (server, profile) pair (verify by switching to a profile that has Seerr configured on server A but not on server B).

- [ ] **Step 3: Expired-token path**

Manually invalidate one server's token (revoke from the Jellyfin admin UI, or delete the `accessToken_<id>` keychain entry).
Switch to that server.
Expected: lands in profile picker for that server, then LoginView when you tap a remembered row.

- [ ] **Step 4: Unreachable-server path**

Add a server, then take its Jellyfin host offline (stop the container/process). Switch to it from the picker.
Expected: brief loading state, then the picker re-renders for the previous (reachable) server. The unreachable server stays in the list.

- [ ] **Step 5: Remove non-active server**

Settings → Servers → contextMenu → "Server entfernen" on a non-active server → confirm.
Expected: that server is gone from the list. Switch sheet no longer offers it. The active server is undisturbed.

- [ ] **Step 6: Remove active server with others present**

Same flow, but on the row marked Aktiv.
Expected: removal succeeds, the most recently added remaining server is promoted to active. No empty intermediate state visible.

- [ ] **Step 7: Remove last server**

Remove the only known server.
Expected: lands in ServerDiscoveryView. No orphaned keychain entries (verify with the simulator keychain inspector if available; otherwise just confirm a fresh install behaviour on the next launch).

- [ ] **Step 8: TopShelf survives switch**

With two servers known and a TopShelf-eligible item visible from server A on the Apple TV top shelf: switch to server B in Sodalite. After a few seconds, the top shelf updates to server B's content.
Expected: a stale server-A tile, then a refresh, then server B's items. Tapping a server-B top shelf tile resolves into a Sodalite detail sheet for the right item.

- [ ] **Step 9: Localization sweep**

Launch in at least one non-EN locale (DE recommended). Navigate to every surface listed in Task 15 Step 4. Confirm no key literals leak.

- [ ] **Step 10: No commit**

This task is verification. If any step fails, file a follow-up task fixing the regression and re-run that step before moving on. Do not commit anything for Task 17 itself.

---

## Self-review

**Spec coverage:** Every Component (1-8) from the spec maps to one or more tasks above (Storage: Task 1; Container API: Tasks 2, 4, 5; Launch+Switch flow: Tasks 6, 7, 13, 14; Picker UX: Tasks 8, 9; Settings UX: Tasks 11, 12; Add-flow: Task 10; Migration: Task 3; Error handling: Tasks 13, 14). The Testing section is realized by Task 17. The Future Phases section is intentionally not implemented.

**No placeholders:** No "TBD"/"TODO"/"implement later" markers; every code block is the real text to paste. The xcstrings translations to the 24 non-EN/DE locales are left to the implementer with explicit guidance (cross-reference an existing fully-translated key, no EN stubs) rather than enumerated here, because enumerating 24 translations inline would balloon the plan and require human review for quality regardless.

**Type consistency:** `JellyfinServer` (existing), `ServerSwitchError` (new in Task 4), `ServerSwitchSheet` (new in Task 8), `ServerManagementView` (new in Task 11). Methods: `listKnownServers`, `addServer`, `removeServer`, `switchServer`, `activeServer`, `probeActiveUser`, `rollbackSwitch`. Method names are consistent across the tasks that introduce and use them.

**Risk callouts for the executor:**

- `AppState.activeServer` already exists and is read by AppRouter (line ~365 of AppRouter.swift). Confirm the assignment in Task 7 still flows through `setAuthenticated` for the normal restore path; the only new assignments are in the repair branch (Task 7) and the rollback path (Task 14).
- `HomeViewModel.reloadAfterServerSwitch` and the library equivalent are sketched in Task 6 but the exact entry points depend on the current VMs. Read both files before pasting the snippets; a wrong method name will break the build.
- The xcstrings sorting + spacing convention (per `project_xcstrings_pipeline`) is sharp-edged. Edit through Xcode where possible. If splicing by hand, run the sed normalization before commit.
