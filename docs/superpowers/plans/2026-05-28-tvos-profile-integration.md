# tvOS Profile Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bridge `TVUserManager.shared.currentUserIdentifier` to Sodalite's (server, profile) tuples so the app reacts to long-press-Home user switches at cold launch and scene-foreground. Auto-record mappings on first login; overridable via a new Apple TV Profile settings sub-screen. TopShelf isolates per system user.

**Architecture:** New `TVProfileMappings` UserDefaults-backed store on `DependencyContainer`. `AppRouter.resolveTVUserContext()` runs at cold launch (before `defaultServerID` promotion) and on `scenePhase == .active`. `SharedSessionMirror` API gains a `tvUserID:` parameter; the existing single-blob keychain slot migrates into a `tvOSSession_default` slot, multi-user writes go to `tvOSSession_<id>`. TopShelf extension reads the current tvOS user's slot.

**Tech Stack:** Swift 6, SwiftUI on tvOS 26+, `TVUIKit.TVUserManager` (tvOS-only API guarded with `#if os(tvOS)`), `KeychainService`, `UserDefaults`. No new dependencies. No test target (manual verification only).

**Spec:** `docs/superpowers/specs/2026-05-28-tvos-profile-integration-design.md` (commit `c61abf08`).

**Build command (used in every verification step):**
```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
  -destination 'generic/platform=tvOS' build
```

**Conventions:**
- No em-dashes anywhere (code, comments, commit messages, this plan).
- Conventional Commits with `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` trailer.
- Push after every commit (`feedback_commit_and_push`).
- The xcstrings file may carry unrelated Xcode-generated churn; stage individual Swift files, not `git add -A`.

---

## File Structure

**New files:**
- `Sodalite/Features/Auth/TVProfileMappings.swift`: the `TVProfileMapping` model and `TVProfileMappings` observable store.
- `Sodalite/App/Environment/TVUserContext.swift`: a tiny utility wrapping the `#if os(tvOS)` guard around `TVUserManager.shared.currentUserIdentifier`. Single source so the guard isn't sprinkled across the codebase.
- `Sodalite/Features/Settings/TVUserProfileSettingsView.swift`: the Apple TV Profile sub-screen.

**Modified files:**
- `Sodalite/App/Environment/DependencyContainer.swift`: holds `tvProfileMappings`, updates `saveSession` / `switchToUser` to auto-record, threads `tvUserID` into all `SharedSessionMirror.write` / `.clear` call sites, hooks `removeServer` / `forgetUser` to clean orphan mappings.
- `Sodalite/Services/Keychain/SharedSessionMirror.swift`: new `tvUserID:` parameter shape; per-tvOS-user keychain slot.
- `Sodalite/Services/Keychain/KeychainKeys.swift`: helper for the new `tvOSSession_<id>` key.
- `Sodalite/Services/Keychain/KeychainMigrator.swift`: one-shot copy of the legacy single-blob slot into `tvOSSession_default`.
- `Sodalite/App/AppRouter.swift`: new `resolveTVUserContext()` called at top of `performRestore` and on `scenePhase == .active`.
- `Sodalite/App/AppState.swift`: nothing structural; observation of `scenePhase` lives in AppRouter via `@Environment(\.scenePhase)`.
- `Sodalite/Features/Settings/SettingsView.swift`: new `SettingsTile` row linking to `TVUserProfileSettingsView`.
- `SodaliteTopShelf/ContentProvider.swift`: read with current tvOS user identifier.
- `SodaliteTopShelf/SharedSession.swift`: same `tvUserID:` parameter shape on the read side.
- `Sodalite/Localizable.xcstrings`: new keys for the settings screen (translated to all 26 locales).

**Not touched:**
- AetherEngine. No engine change.
- The existing multi-server primitives (`switchServer`, `removeServer`, etc.). They get new call sites but no signature changes.
- `AuthPreferences`. Mappings are global (per Apple TV), not per Sodalite profile.

---

## Task 1: `TVUserContext` helper

**Files:**
- Create: `Sodalite/App/Environment/TVUserContext.swift`

A one-liner utility that wraps `TVUserManager.shared.currentUserIdentifier` behind the `#if os(tvOS)` guard. Every other touchpoint calls this instead of importing `TVUIKit` itself.

- [ ] **Step 1: Write the file**

```swift
import Foundation
#if os(tvOS)
import TVUIKit
#endif

/// Resolves the system-level tvOS user identifier when multi-user
/// mode is active. Returns nil on Apple TVs without multi-user
/// (older models, single-user setup, or non-tvOS targets). Callers
/// use the nil case as "behave like before, no per-user routing."
enum TVUserContext {
    static var currentUserID: String? {
        #if os(tvOS)
        if #available(tvOS 13, *) {
            return TVUserManager.shared.currentUserIdentifier
        }
        #endif
        return nil
    }
}
```

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Sodalite/App/Environment/TVUserContext.swift
git commit -m "$(cat <<'EOF'
chore(tvOS): add TVUserContext helper

Single source for reading TVUserManager.shared.currentUserIdentifier
behind the #if os(tvOS) guard so other call sites don't have to
import TVUIKit or repeat the platform check.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 2: `TVProfileMapping` model + `TVProfileMappings` store

**Files:**
- Create: `Sodalite/Features/Auth/TVProfileMappings.swift`

The persistent map of `tvUserID → (serverID, jellyfinUserID)`. UserDefaults-backed, JSON-encoded single key. `@Observable` so the settings UI re-renders on writes.

- [ ] **Step 1: Write the file**

```swift
import Foundation
import Observation

/// Persistent binding between a tvOS system user (as reported by
/// TVUserManager.shared.currentUserIdentifier) and a Sodalite
/// (server, Jellyfin profile) tuple. Mappings get auto-recorded the
/// first time a tvOS user successfully signs into a profile, and
/// can be overridden manually from the Apple TV Profile settings
/// sub-screen.
struct TVProfileMapping: Codable, Sendable, Equatable {
    let serverID: String
    let jellyfinUserID: String
}

/// UserDefaults-backed store for `[tvUserID: TVProfileMapping]`.
/// The whole table lives behind a single JSON-encoded key so reads
/// and writes are atomic. Not keychain-backed: the table contains
/// only identifiers, no tokens or other secrets, and we want it to
/// be syncable later via iCloud KVS without a security review.
@Observable
@MainActor
final class TVProfileMappings {

    private enum Keys {
        static let mappings = "tvOS.profileMappings"
    }

    private let store: UserDefaults
    private(set) var allMappings: [String: TVProfileMapping] = [:]

    init(store: UserDefaults = .standard) {
        self.store = store
        self.allMappings = Self.load(from: store)
    }

    /// Returns the mapping for the given tvOS user identifier, or
    /// nil if none has been recorded yet.
    func mapping(for tvUserID: String) -> TVProfileMapping? {
        allMappings[tvUserID]
    }

    /// Upserts a mapping. Passing nil removes the entry for that
    /// tvOS user. Re-recording an identical mapping is a no-op
    /// (auto-record paths call this repeatedly and shouldn't churn
    /// the disk on every login).
    func setMapping(_ mapping: TVProfileMapping?, for tvUserID: String) {
        if let mapping {
            if allMappings[tvUserID] == mapping { return }
            allMappings[tvUserID] = mapping
        } else {
            if allMappings[tvUserID] == nil { return }
            allMappings.removeValue(forKey: tvUserID)
        }
        persist()
    }

    /// Removes every mapping that points at the given server. Called
    /// when a server is removed from the multi-server schema.
    func removeMappings(forServer serverID: String) {
        let filtered = allMappings.filter { $0.value.serverID != serverID }
        if filtered.count == allMappings.count { return }
        allMappings = filtered
        persist()
    }

    /// Removes a single (server, user) mapping. Called when a
    /// remembered user is forgotten from the profile picker.
    func removeMapping(forUser userID: String, on serverID: String) {
        let filtered = allMappings.filter {
            !($0.value.serverID == serverID && $0.value.jellyfinUserID == userID)
        }
        if filtered.count == allMappings.count { return }
        allMappings = filtered
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(allMappings) else { return }
        store.set(data, forKey: Keys.mappings)
    }

    private static func load(from store: UserDefaults) -> [String: TVProfileMapping] {
        guard let data = store.data(forKey: Keys.mappings) else { return [:] }
        return (try? JSONDecoder().decode([String: TVProfileMapping].self, from: data)) ?? [:]
    }
}
```

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Features/Auth/TVProfileMappings.swift
git commit -m "$(cat <<'EOF'
feat(tvOS): add TVProfileMapping model + TVProfileMappings store

UserDefaults-backed @Observable store that holds the mapping table
from tvOS system user identifier to (serverID, jellyfinUserID).
Single JSON-encoded key for atomic reads/writes. setMapping/
removeMappings are idempotent so auto-record paths can call them
on every login without churning the disk.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 3: Wire `TVProfileMappings` into DependencyContainer

**Files:**
- Modify: `Sodalite/App/Environment/DependencyContainer.swift`

Instantiate the store, expose it as a public property, hook the orphan-cleanup calls into `removeServer` and `forgetUser`.

- [ ] **Step 1: Add the property**

After the existing `authPreferences` property declaration in `DependencyContainer`:

```swift
    let tvProfileMappings: TVProfileMappings
```

In the init, after `self.authPreferences = AuthPreferences(...)`:

```swift
        self.tvProfileMappings = TVProfileMappings()
```

- [ ] **Step 2: Hook into removeServer**

At the end of `removeServer(id:)`, after the existing per-server keychain deletions but BEFORE the active-promotion branch, add:

```swift
        tvProfileMappings.removeMappings(forServer: serverID)
```

This places the cleanup BEFORE the successor switch so the cleanup is reflected if the successor promotion triggers a recursive flow.

- [ ] **Step 3: Hook into forgetUser**

In `forgetUser(id:serverID:)`, after the existing remembered-users + Seerr cleanup but before the function returns, add:

```swift
        tvProfileMappings.removeMapping(forUser: id, on: serverID)
```

- [ ] **Step 4: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Sodalite/App/Environment/DependencyContainer.swift
git commit -m "$(cat <<'EOF'
feat(container): hold TVProfileMappings + auto-clean orphans

The container now owns the TVProfileMappings store. removeServer
and forgetUser call the targeted cleanup helpers so a mapping
pointing at a removed server or forgotten profile is dropped
synchronously. The next foreground for that tvOS user then falls
through to the default-server / picker flow instead of trying to
switch to a server that no longer exists.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 4: Auto-record mappings on `saveSession` + `switchToUser`

**Files:**
- Modify: `Sodalite/App/Environment/DependencyContainer.swift`

Whenever a successful authentication writes session state, also stamp the current tvOS user's mapping.

- [ ] **Step 1: Append to saveSession**

At the end of `saveSession(server:user:token:password:)`, after the `rememberUser(...)` call:

```swift
        if let tvUserID = TVUserContext.currentUserID {
            tvProfileMappings.setMapping(
                TVProfileMapping(serverID: server.id, jellyfinUserID: user.id),
                for: tvUserID
            )
        }
```

- [ ] **Step 2: Append to switchToUser**

At the end of `switchToUser(_:server:)`, after the existing SharedSessionMirror.write call:

```swift
        if let tvUserID = TVUserContext.currentUserID {
            tvProfileMappings.setMapping(
                TVProfileMapping(serverID: server.id, jellyfinUserID: remembered.id),
                for: tvUserID
            )
        }
```

The argument inside `switchToUser` is named `remembered` per the existing signature; adapt the field reference if a different local name exists in the actual code.

- [ ] **Step 3: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Sodalite/App/Environment/DependencyContainer.swift
git commit -m "$(cat <<'EOF'
feat(container): auto-record tvOS profile mapping on auth

Every successful saveSession + switchToUser path now records the
current tvOS user's mapping. Idempotent: re-running the same
authentication doesn't churn the table. On Apple TVs without
multi-user, TVUserContext.currentUserID is nil and the record
step is a no-op.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 5: Extend `KeychainKeys` for per-tvOS-user session slots

**Files:**
- Modify: `Sodalite/Services/Keychain/KeychainKeys.swift`

Helper that produces the keychain key for the per-tvOS-user shared session slot. A nil identifier folds into the `default` slot so the no-multi-user path stays single-blob.

- [ ] **Step 1: Add the helper**

Near the other key helpers:

```swift
    /// Shared-session blob slot keyed by tvOS system user. Nil
    /// (single-user Apple TV) lands in the `default` slot so the
    /// no-multi-user path keeps using one blob, same as today.
    /// Multi-user writes land in a per-identifier slot, which the
    /// TopShelf extension reads via TVUserManager.
    static func sharedSession(tvUserID: String?) -> String {
        "tvOSSession_\(tvUserID ?? "default")"
    }
```

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Services/Keychain/KeychainKeys.swift
git commit -m "$(cat <<'EOF'
chore(keychain): add per-tvOS-user shared-session key helper

KeychainKeys.sharedSession(tvUserID:) produces the keychain key
for the SharedSessionMirror blob. Nil folds into the `default`
slot so single-user installs stay single-blob; multi-user writes
land in per-identifier slots that the TopShelf extension reads
via TVUserManager.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 6: Per-tvOS-user `SharedSessionMirror`

**Files:**
- Modify: `Sodalite/Services/Keychain/SharedSessionMirror.swift`

Adapt the write/clear/read API to accept an optional `tvUserID`. Internally route to `KeychainKeys.sharedSession(tvUserID:)`.

- [ ] **Step 1: Update the public API**

Replace the existing `write` and `clear` (and any read helper) with tvUserID-aware versions. The current API likely looks like:

```swift
struct SharedSessionMirror {
    static func write(serverURL: URL, userID: String, accessToken: String)
    static func clear()
}
```

Read the file to confirm the actual shape, then add `tvUserID:` as the FIRST parameter on each:

```swift
struct SharedSessionMirror {
    static func write(tvUserID: String?, serverURL: URL, userID: String, accessToken: String) {
        // existing body, but use KeychainKeys.sharedSession(tvUserID:) as the slot key
        let slot = KeychainKeys.sharedSession(tvUserID: tvUserID)
        // ... encode SharedSession blob, save to keychain at `slot` ...
    }

    static func clear(tvUserID: String?) {
        let slot = KeychainKeys.sharedSession(tvUserID: tvUserID)
        // ... delete keychain entry at `slot` ...
    }

    /// Wipes EVERY tvOS-user-keyed slot plus the default one. Used
    /// by clearSession (full logout) so a multi-user setup doesn't
    /// leave one user's mirror behind after a global wipe.
    static func clearAll() {
        // Enumerate by reading TVProfileMappings? No, that's not
        // visible here. Instead, the keychain query model: query
        // all generic-password items whose account begins with
        // "tvOSSession_" and delete each. Implementation uses the
        // same Security framework call style KeychainMigrator uses.
        // ... SecItemDelete with kSecMatchLimit-all on the prefix ...
    }
}
```

The `clearAll` body needs a keychain prefix-delete; if the existing `KeychainService` doesn't expose one, add a minimal `SecItemDelete` query inline (it lives behind `Security` imports). Concrete sketch:

```swift
    static func clearAll() {
        // Delete every shared-session blob (default + per-tvOS-user).
        // SecItem doesn't accept prefix matching, so we list every
        // account under the service and delete each whose name
        // begins with "tvOSSession_".
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix("tvOSSession_")
            else { continue }
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: KeychainKeys.service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }
```

- [ ] **Step 2: Update every call site in Sodalite-side code**

Grep `git grep "SharedSessionMirror\.\(write\|clear\)" Sodalite/` to find each call. Wrap each with the current tvOS user:

```swift
        SharedSessionMirror.write(
            tvUserID: TVUserContext.currentUserID,
            serverURL: server.url,
            userID: userID,
            accessToken: token
        )
```

```swift
        SharedSessionMirror.clear(tvUserID: TVUserContext.currentUserID)
```

In `clearSession()` (the full-logout path), replace `SharedSessionMirror.clear()` with `SharedSessionMirror.clearAll()` so every tvOS user's slot is wiped.

- [ ] **Step 3: Update the TopShelf-side reader**

`SodaliteTopShelf/SharedSession.swift` has the read side. Add a `read(tvUserID:)` accessor mirroring the write API:

```swift
extension SharedSession {
    static func read(tvUserID: String?) -> SharedSession? {
        let slot = KeychainKeys.sharedSession(tvUserID: tvUserID)
        // ... existing load-from-keychain logic, but pass `slot` as the account ...
    }
}
```

The existing `SharedSession.read()` (no args) becomes `read(tvUserID: nil)` for legacy callers.

- [ ] **Step 4: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Sodalite/Services/Keychain/SharedSessionMirror.swift Sodalite/App/Environment/DependencyContainer.swift SodaliteTopShelf/SharedSession.swift
git commit -m "$(cat <<'EOF'
feat(tvOS): per-user SharedSessionMirror slots

SharedSessionMirror.write/clear/read now accept tvUserID. The blob
lands in tvOSSession_<id> for multi-user setups; nil folds into
tvOSSession_default for single-user Apple TVs. clearSession uses
a new clearAll helper that enumerates every tvOSSession_* slot
and wipes them so a full logout doesn't strand one user's mirror.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 7: Migrate the legacy single-blob slot

**Files:**
- Modify: `Sodalite/Services/Keychain/KeychainMigrator.swift`

A one-shot copy of the legacy single-blob slot (whatever account name it currently uses) into `tvOSSession_default`. Idempotent.

- [ ] **Step 1: Add the migration step**

Add a new flag key and migration function to `KeychainMigrator`, paralleling the existing `migrateActiveServerToMultiIfNeeded` step. Look up the legacy slot name in the current SharedSessionMirror source (it's likely `"sharedSession"` or similar; confirm by reading the file before applying):

```swift
    private static let sharedSessionMigratedFlagKey = "Sodalite.didMigrateSharedSessionToTVUser.v1"
    private static let legacySharedSessionSlot = "sharedSession"  // adapt to actual

    static func migrateSharedSessionToTVUserSlotIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: sharedSessionMigratedFlagKey) else { return }

        let keychain = KeychainService(service: newMainService)

        // Skip cleanly if the legacy slot is empty or the new slot
        // already has data (fresh install, prior partial migration).
        let defaultSlot = KeychainKeys.sharedSession(tvUserID: nil)
        if (try? keychain.loadData(for: defaultSlot)) != nil {
            defaults.set(true, forKey: sharedSessionMigratedFlagKey)
            return
        }
        guard let legacyBlob = try? keychain.loadData(for: legacySharedSessionSlot)
        else {
            defaults.set(true, forKey: sharedSessionMigratedFlagKey)
            return
        }

        do {
            try keychain.save(legacyBlob, for: defaultSlot)
            try? keychain.delete(for: legacySharedSessionSlot)
            log.notice("KeychainMigrator: sharedSession -> tvOSSession_default")
        } catch {
            log.notice("KeychainMigrator: sharedSession -> tvOSSession migration failed: \(String(describing: error), privacy: .public)")
            return
        }

        defaults.set(true, forKey: sharedSessionMigratedFlagKey)
    }
```

- [ ] **Step 2: Wire into migrateIfNeeded**

Inside `migrateIfNeeded`, after the `migrateActiveServerToMultiIfNeeded()` call:

```swift
        migrateSharedSessionToTVUserSlotIfNeeded()
```

- [ ] **Step 3: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Sodalite/Services/Keychain/KeychainMigrator.swift
git commit -m "$(cat <<'EOF'
chore(keychain): migrate legacy SharedSession blob to tvOS slot

One-shot copy of the pre-tvOS-user-aware sharedSession keychain
slot into tvOSSession_default. Idempotent via its own flag,
independent of the activeServer migration's flag. After the
migration runs the legacy account is deleted so single-user
installs read only the new slot.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 8: `AppRouter.resolveTVUserContext` at cold launch

**Files:**
- Modify: `Sodalite/App/AppRouter.swift`

Add the resolver method and call it at the top of `performRestore`, BEFORE the existing `defaultServerID` promotion block.

- [ ] **Step 1: Add the helper method**

In `AppRouter`, add (placement: near the other private async helpers like `resolveContinueWatchingRequest`):

```swift
    /// Promote the (server, profile) tuple pinned to the current
    /// tvOS user, if any. Runs at the top of performRestore and on
    /// every scene-foreground. The tvOS mapping wins over the user's
    /// defaultServerID, the system identity is the more specific
    /// signal. On Apple TVs without multi-user this is a no-op.
    private func resolveTVUserContext() async {
        guard let tvUserID = TVUserContext.currentUserID else { return }
        guard let mapping = dependencies.tvProfileMappings.mapping(for: tvUserID) else { return }

        let currentServerID = try? dependencies.keychainService.loadString(
            for: KeychainKeys.activeServerID
        )
        let currentUserID = try? dependencies.keychainService.loadString(
            for: KeychainKeys.userID(serverID: mapping.serverID)
        )
        guard currentServerID != mapping.serverID
            || currentUserID != mapping.jellyfinUserID
        else { return }

        try? dependencies.switchServer(to: mapping.serverID)
        if let server = dependencies.activeServer,
           let user = dependencies.listRememberedUsers(serverID: mapping.serverID)
               .first(where: { $0.id == mapping.jellyfinUserID }) {
            try? dependencies.switchToUser(user, server: server)
        }
    }
```

- [ ] **Step 2: Call from performRestore**

At the very TOP of `performRestore`, right after the StoreKit fire-and-forget Task block and BEFORE the existing default-server promotion block added in Task 5 of the multi-server plan, add:

```swift
        await resolveTVUserContext()
```

- [ ] **Step 3: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Sodalite/App/AppRouter.swift
git commit -m "$(cat <<'EOF'
feat(router): resolve tvOS user mapping at cold launch

performRestore now calls resolveTVUserContext before the default-
server promotion block. If the current tvOS user has a mapping in
TVProfileMappings, the active-server pointer + per-server user
slot are switched to the mapping target before restoreSession
runs. No-op on single-user Apple TVs or for tvOS users that have
no mapping recorded yet.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 9: React on scene foreground

**Files:**
- Modify: `Sodalite/App/AppRouter.swift`

Observe `scenePhase` so a long-press-Home user switch is honoured the next time Sodalite reaches `.active`.

- [ ] **Step 1: Add the environment property**

At the top of the AppRouter struct's properties:

```swift
    @Environment(\.scenePhase) private var scenePhase
```

- [ ] **Step 2: Observe transitions to `.active`**

In `AppRouter.body`, chain a `.task(id:)` after the existing observers (after `.task(id: appState.serverDidSwitch)` for example):

```swift
        .task(id: scenePhase) {
            // Only react to becoming active. Inactive and background
            // transitions don't need a tvOS-user re-resolve.
            guard scenePhase == .active else { return }
            // Skip the first firing at app launch, performRestore
            // already runs resolveTVUserContext there.
            guard appState.isAuthenticated || launchPickerServer != nil else { return }
            await resolveTVUserContext()
        }
```

The guard on `appState.isAuthenticated || launchPickerServer != nil` skips the very first `.active` firing during launch, when `performRestore` is the authoritative resolver. Subsequent foreground transitions (after the user backgrounds the app, switches tvOS users, and returns) fire when at least one of those state markers is true.

- [ ] **Step 3: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Sodalite/App/AppRouter.swift
git commit -m "$(cat <<'EOF'
feat(router): re-resolve tvOS user mapping on foreground

AppRouter now observes scenePhase and re-runs resolveTVUserContext
on every transition to .active (skipping the launch firing, which
performRestore handles). A long-press-Home user switch is honoured
the next time the user returns to Sodalite.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 10: TopShelf reads per-tvOS-user slot

**Files:**
- Modify: `SodaliteTopShelf/ContentProvider.swift`

The extension lives in a separate process. It can call `TVUserManager.shared.currentUserIdentifier` directly (the API is available to the extension).

- [ ] **Step 1: Update `loadTopShelfContent`**

Find the line in `loadTopShelfContent()` that calls `SharedSession.read()` (or similar). Replace:

```swift
        let tvUserID: String?
        if #available(tvOS 13, *) {
            tvUserID = TVUserManager.shared.currentUserIdentifier
        } else {
            tvUserID = nil
        }
        guard let session = SharedSession.read(tvUserID: tvUserID) else { return nil }
```

The `TVUIKit` import probably already exists at the top of `ContentProvider.swift` because the file uses `TVTopShelf...` types. If not, add `import TVUIKit`.

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add SodaliteTopShelf/ContentProvider.swift
git commit -m "$(cat <<'EOF'
feat(topshelf): read per-tvOS-user session blob

ContentProvider now passes TVUserManager.shared.currentUserIdentifier
into SharedSession.read so each system user's TopShelf tile shows
that user's Continue Watching / Next Up. nil identifier (single-
user Apple TV) reads the default slot, identical to today's
behaviour.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 11: `TVUserProfileSettingsView`

**Files:**
- Create: `Sodalite/Features/Settings/TVUserProfileSettingsView.swift`

Settings sub-screen listing every recorded mapping plus a synthetic row for the current tvOS user if it has none yet.

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

/// Settings sub-screen for the Apple TV Profile mappings. Lists
/// every entry in TVProfileMappings.allMappings plus a synthetic
/// "current tvOS user" row when the current identifier has no
/// mapping yet. On Apple TVs without multi-user, shows a single
/// read-only "Shared session" row with an explanatory caption.
struct TVUserProfileSettingsView: View {
    @Environment(\.dependencies) private var dependencies
    @State private var mappings: [(tvUserID: String, mapping: TVProfileMapping?)] = []
    @State private var editing: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("tvOSProfile.title", bundle: .main)
                    .font(.largeTitle.bold())
                    .padding(.bottom, 8)

                if TVUserContext.currentUserID == nil {
                    sharedSessionRow
                } else {
                    ForEach(mappings, id: \.tvUserID) { entry in
                        TVProfileRow(
                            tvUserID: entry.tvUserID,
                            mapping: entry.mapping,
                            isCurrent: entry.tvUserID == TVUserContext.currentUserID,
                            servers: dependencies.listKnownServers(),
                            resolveProfile: { id in
                                guard let m = entry.mapping else { return nil }
                                return dependencies.listRememberedUsers(serverID: m.serverID)
                                    .first(where: { $0.id == m.jellyfinUserID })?.name
                            },
                            onEdit: { editing = entry.tvUserID },
                            onRemove: {
                                dependencies.tvProfileMappings.setMapping(nil, for: entry.tvUserID)
                                load()
                            }
                        )
                    }
                }

                Text("tvOSProfile.footer.hint", bundle: .main)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .onAppear(perform: load)
        .sheet(isPresented: Binding(
            get: { editing != nil },
            set: { if !$0 { editing = nil } }
        )) {
            if let tvUserID = editing {
                TVProfileEditSheet(
                    tvUserID: tvUserID,
                    onSave: { mapping in
                        dependencies.tvProfileMappings.setMapping(mapping, for: tvUserID)
                        editing = nil
                        load()
                    },
                    onCancel: { editing = nil }
                )
            }
        }
    }

    private var sharedSessionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "person.circle")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("tvOSProfile.sharedSession.title", bundle: .main)
                    .font(.headline)
            }
            Text("tvOSProfile.sharedSession.caption", bundle: .main)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func load() {
        let stored = dependencies.tvProfileMappings.allMappings
        var entries: [(String, TVProfileMapping?)] = stored.map { ($0.key, $0.value) }
        if let currentID = TVUserContext.currentUserID,
           stored[currentID] == nil {
            entries.append((currentID, nil))
        }
        // Current tvOS user first, then alphabetically.
        entries.sort { lhs, rhs in
            if lhs.0 == TVUserContext.currentUserID { return true }
            if rhs.0 == TVUserContext.currentUserID { return false }
            return lhs.0 < rhs.0
        }
        mappings = entries.map { (tvUserID: $0.0, mapping: $0.1) }
    }
}

private struct TVProfileRow: View {
    let tvUserID: String
    let mapping: TVProfileMapping?
    let isCurrent: Bool
    let servers: [JellyfinServer]
    let resolveProfile: (String) -> String?
    let onEdit: () -> Void
    let onRemove: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if isCurrent {
                    Text("tvOSProfile.row.current", bundle: .main)
                        .font(.caption.bold())
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.tint.opacity(0.18), in: Capsule())
                }
                Text(tvUserIDDisplay)
                    .font(.headline)
                    .lineLimit(1)
            }
            if let mapping {
                let serverName = servers.first(where: { $0.id == mapping.serverID })?.name
                    ?? mapping.serverID
                let profileName = resolveProfile(mapping.jellyfinUserID) ?? mapping.jellyfinUserID
                Text("tvOSProfile.row.bound \(serverName) \(profileName)", bundle: .main)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("tvOSProfile.row.unbound", bundle: .main)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? Color.white.opacity(0.15) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(focused ? 1 : 0)
        )
        .focusable(true)
        .focused($focused)
        .stableTap(isFocused: focused, perform: onEdit)
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label {
                    Text("tvOSProfile.row.action.edit", bundle: .main)
                } icon: {
                    Image(systemName: "pencil")
                }
            }
            if mapping != nil {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label {
                        Text("tvOSProfile.row.action.remove", bundle: .main)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }

    /// The tvOS identifier is an opaque string. Show the first 8
    /// characters with an ellipsis so the rows are visually
    /// distinguishable without taking the whole width.
    private var tvUserIDDisplay: String {
        let prefix = tvUserID.prefix(8)
        return tvUserID.count > 8 ? "\(prefix)…" : String(prefix)
    }
}

private struct TVProfileEditSheet: View {
    let tvUserID: String
    let onSave: (TVProfileMapping) -> Void
    let onCancel: () -> Void
    @Environment(\.dependencies) private var dependencies
    @State private var selectedServerID: String?
    @State private var selectedUserID: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("tvOSProfile.editSheet.title", bundle: .main)
                .font(.title2.bold())
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(dependencies.listKnownServers()) { server in
                        let users = dependencies.listRememberedUsers(serverID: server.id)
                        ForEach(users) { user in
                            row(server: server, user: user)
                        }
                    }
                }
                .padding(.horizontal, 40)
            }
            HStack(spacing: 24) {
                Button("common.cancel") { onCancel() }
                Button("common.save") {
                    if let sid = selectedServerID, let uid = selectedUserID {
                        onSave(TVProfileMapping(serverID: sid, jellyfinUserID: uid))
                    }
                }
                .disabled(selectedServerID == nil || selectedUserID == nil)
            }
        }
        .frame(maxWidth: 900, maxHeight: 700)
        .padding(40)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func row(server: JellyfinServer, user: RememberedUser) -> some View {
        Button {
            selectedServerID = server.id
            selectedUserID = user.id
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(user.name).font(.headline)
                    Text(server.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selectedServerID == server.id, selectedUserID == user.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(.card)
    }
}
```

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED` (with warnings for missing localization keys — those land in Task 13).

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Features/Settings/TVUserProfileSettingsView.swift
git commit -m "$(cat <<'EOF'
feat(settings): add TVUserProfileSettingsView

Settings sub-screen listing every TVProfileMappings entry plus a
synthetic row for the current tvOS user when it has no mapping
yet. Per-row stableTap opens an edit sheet that lets the user
pick any (server, remembered profile) combination. Apple TVs
without multi-user see a single read-only "Shared session" row
with an explanatory caption. Localization keys land in a later
task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 12: Link `TVUserProfileSettingsView` from `SettingsView`

**Files:**
- Modify: `Sodalite/Features/Settings/SettingsView.swift`

Add a `SettingsTile` row immediately below the "Servers" tile added in the multi-server plan.

- [ ] **Step 1: Add the tile**

Find the existing `SettingsTile(icon: "server.rack", ...)` block in `SettingsView.body` and add a new tile right after it:

```swift
            SettingsTile(
                icon: "person.crop.rectangle",
                title: "tvOSProfile.settings.entry.title",
                subtitle: "tvOSProfile.settings.entry.subtitle",
                destination: TVUserProfileSettingsView()
            )
```

The exact API of `SettingsTile` matches the row added in Task 12 of the multi-server plan; if the actual constructor uses different parameter labels, adapt accordingly while keeping the icon + the two localization keys consistent.

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Features/Settings/SettingsView.swift
git commit -m "$(cat <<'EOF'
feat(settings): link TVUserProfileSettingsView entry

New SettingsTile row immediately below the Servers entry. Same
component, person-crop icon, two-line description. Localized
strings ship in a follow-on i18n task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 13: Localization for all 26 locales

**Files:**
- Modify: `Sodalite/Localizable.xcstrings`

The 12 new keys introduced by Tasks 11 + 12:

| Key | EN | DE |
| --- | --- | --- |
| `tvOSProfile.title` | Apple TV Profile | Apple TV-Profil |
| `tvOSProfile.footer.hint` | Mappings are recorded automatically on first login. Long-press a row to edit or remove. | Verknüpfungen werden bei der ersten Anmeldung automatisch gespeichert. Eintrag lange drücken zum Bearbeiten oder Entfernen. |
| `tvOSProfile.sharedSession.title` | Shared session | Geteilte Sitzung |
| `tvOSProfile.sharedSession.caption` | Multi-user mode is not active on this Apple TV. All system users share one Sodalite session. | Multi-User-Modus ist auf dieser Apple TV nicht aktiv. Alle Systemnutzer teilen sich eine Sodalite-Sitzung. |
| `tvOSProfile.row.current` | Current | Aktuell |
| `tvOSProfile.row.bound %@ %@` | Server "%@" · Profile "%@" | Server "%@" · Profil "%@" |
| `tvOSProfile.row.unbound` | No profile assigned yet. | Noch kein Profil zugewiesen. |
| `tvOSProfile.row.action.edit` | Edit mapping | Verknüpfung bearbeiten |
| `tvOSProfile.row.action.remove` | Remove mapping | Verknüpfung entfernen |
| `tvOSProfile.editSheet.title` | Pick a profile | Profil wählen |
| `tvOSProfile.settings.entry.title` | Apple TV Profile | Apple TV-Profil |
| `tvOSProfile.settings.entry.subtitle` | Pin a Jellyfin profile to each tvOS user. | Verknüpfe ein Jellyfin-Profil mit jedem tvOS-Nutzer. |

`common.save` is needed too if it doesn't already exist in xcstrings; check first and only add it if absent (it's a generic key likely already present from prior work).

- [ ] **Step 1: Add the 12 keys**

Use the Task 15 (multi-server) localization pattern: each key has `localizations` containing every locale in the 26-locale set (cs, da, de, el, en, es, fi, fr, hr, hu, it, ja, ko, nb, nl, pl, pt-BR, pt-PT, ro, ru, sk, sv, tr, uk, zh-Hans, zh-Hant), each with `"state": "translated"` and a real translation. Insert in alphabetical position.

For locales beyond EN/DE, produce idiomatic translations of the short UI text (the longer footer hint and sharedSession caption are the only sentences-not-fragments). Match register: informal "du" in DE, casual everywhere.

The two interpolation keys (`tvOSProfile.row.bound %@ %@`) need both `%@` placeholders preserved in every translation, with the right relative order for the language ("Server X, Profile Y" reads as "Profil Y auf Server X" in some locales — keep the format-specifier ordering matching the SwiftUI call site).

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED` with no missing-strings warnings for any tvOSProfile.* key.

- [ ] **Step 3: Visual sweep**

Launch the app in DE and EN, navigate to Settings → Apple TV Profile, confirm no raw key literals leak.

- [ ] **Step 4: Commit**

```bash
git add Sodalite/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
i18n(settings): add Apple TV Profile strings to all locales

12 new keys for the Apple TV Profile sub-screen (title + footer
hint + shared-session row + bound/unbound row + actions + edit
sheet + Settings entry tile). Translated across all 26 supported
locales with state "translated" (no EN-cloned stubs).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 14: Changelog 0.9.0 entry

**Files:**
- Modify: `Sodalite/Features/Changelog/Changelog.swift`
- Modify: `Sodalite/Localizable.xcstrings`

The multi-server work already landed under the 0.8.0 changelog entry. tvOS Profile Integration ships as the 0.9.0 highlight.

- [ ] **Step 1: Add the entry above 0.8.0**

Follow the pattern from the multi-server Task 16 commit (`03684e98`). The entry is:

```swift
    ChangelogEntry(
        version: "0.9.0",
        highlights: [
            ChangelogHighlight(
                .new,
                "changelog.0_9_0.tvOSProfile.title",
                "changelog.0_9_0.tvOSProfile.body",
                icon: "person.crop.rectangle"
            )
        ]
    ),
```

Place it at the top of the `entries` array, above the 0.8.0 entry.

Body text:

- **EN headline:** Apple TV Profile mapping
- **DE headline:** Apple TV-Profil-Verknüpfung
- **EN body:** Sodalite now follows your Apple TV system user. Sign in once and Sodalite routes the right Jellyfin profile every time you switch via long-press-Home. TopShelf shows the right Continue Watching per user. Edit the mappings under Settings → Apple TV Profile.
- **DE body:** Sodalite folgt jetzt deinem Apple TV-Systemnutzer. Einmal anmelden und Sodalite wechselt das richtige Jellyfin-Profil bei jedem Long-Press-Home. TopShelf zeigt das passende Continue Watching pro Nutzer. Verknüpfungen anpassen unter Einstellungen → Apple TV-Profil.

Translated to all 26 locales the same way.

- [ ] **Step 2: Build**

`xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Features/Changelog/Changelog.swift Sodalite/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
feat(changelog): add 0.9.0 tvOS profile entry

Translated for all 26 locales.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 15: Manual verification pass

No code changes. This is the "verification before completion" gate.

- [ ] **Step 1: Multi-user happy path**

On an Apple TV 4K with multi-user enabled (Settings → Users and Accounts → Add User added):

1. Launch Sodalite as tvOS User A. Sign in to jelly-arrstack as Vince. Expected: mapping (A → jelly-arrstack, Vince) recorded.
2. Background Sodalite. Long-press Home → switch to tvOS User B. Launch Sodalite. Sign in as Joser (or any other Jellyfin profile / server). Mapping (B → ..., Joser) recorded.
3. Long-press Home → switch back to User A. Bring Sodalite to foreground. Expected: lands in Vince/jelly-arrstack within a frame or two of foreground.
4. Switch to User B. Foreground Sodalite. Expected: lands in Joser/that-server.

- [ ] **Step 2: TopShelf isolation**

After Step 1's setup, return to tvOS Home as User A. The Sodalite TopShelf tile shows Vince's Continue Watching / Next Up. Switch to User B. The TopShelf tile (after a system refresh) shows B's Sodalite items.

- [ ] **Step 3: Forget mapped profile**

Open Sodalite as User A. From the LaunchProfilePicker, long-press the Vince card → Forget profile. Background, foreground again as User A. Expected: LaunchProfilePicker for jelly-arrstack with no Vince card (other remembered profiles still visible if any).

- [ ] **Step 4: Remove mapped server**

Settings → Servers → Remove jelly-arrstack. Background, foreground as User A. Expected: defaultServerID path (or if no default, the most recently added remaining server's profile picker).

- [ ] **Step 5: Single-user Apple TV**

On an Apple TV without multi-user enabled, install the same build. Cold-launch: behaviour matches the multi-server-only build. Settings → Apple TV Profile shows the "Shared session" read-only row.

- [ ] **Step 6: Settings override**

Multi-user-enabled Apple TV. Open Settings → Apple TV Profile. Tap the current tvOS user's row. Pick a different (server, profile). Background, foreground. Expected: app switches to the new mapping.

- [ ] **Step 7: Migration check**

Install the last build before this plan (commit `5d3e5867` is the TopShelf-fix commit, before any tvOS-profile work). Sign in. Quit. Install this plan's build. Launch. Expected: the legacy single-blob session blob has migrated into `tvOSSession_default`; TopShelf still shows items; the app still recognises the active session.

- [ ] **Step 8: No commit**

This task is verification only.

---

## Self-review

**Spec coverage:** Every spec section maps to one or more tasks:
- Storage (Component 1): Task 2.
- TVProfileMappings API (Component 2): Task 2 + Task 3 (cleanup hooks).
- AppRouter lifecycle hooks (Component 3): Tasks 8 + 9.
- Auto-recording (Component 4): Task 4.
- SharedSessionMirror per-user (Component 5): Tasks 5, 6, 7, 10.
- Settings UI (Component 6): Tasks 11 + 12.
- Edge cases (Component 7): folded into the relevant tasks (single-user fallback in Tasks 1, 6, 11; orphan cleanup in Task 3).
- Testing (Component 8): Task 15.
- Future phases: not implemented, explicitly out of scope.

**No placeholders:** No "TBD" or "implement later" markers. The 24 non-EN/DE translations in Task 13 are described as "produce idiomatic translations" with explicit register guidance, mirroring the multi-server Task 15 approach.

**Type consistency:** `TVProfileMapping` (Task 2) is used in Tasks 3, 4, 8, 11. `TVProfileMappings.allMappings` / `mapping(for:)` / `setMapping(_:for:)` / `removeMappings(forServer:)` / `removeMapping(forUser:on:)` are introduced in Task 2 and called by the names above in Tasks 3, 4, 8, 11. `TVUserContext.currentUserID` from Task 1 is called from Tasks 4, 8, 9, 11. `KeychainKeys.sharedSession(tvUserID:)` from Task 5 is consumed by Tasks 6 + 7.

**Risk callouts:**

- `SettingsTile`'s actual init parameter labels weren't shown to me directly; Task 12 references the multi-server Task 12 commit as the pattern. If the labels differ, adapt in place.
- The legacy SharedSession keychain account name in Task 7 is assumed to be `"sharedSession"`. Read `Sodalite/Services/Keychain/SharedSessionMirror.swift` before applying to confirm.
- `Sodalite/Features/Auth/TVProfileMappings.swift` lives under `Features/Auth/` for proximity to `AuthPreferences.swift`. If a different placement (e.g. `App/Environment/`) reads cleaner, move it; downstream tasks import only from `Sodalite` so the move is transparent.
- The `tvUserIDDisplay` truncation in Task 11 is a first-cut approximation; if the tvOS identifier is shorter than expected in practice, the truncation is a no-op and the full ID renders.
