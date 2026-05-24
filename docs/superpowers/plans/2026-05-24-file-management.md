# File Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface a permission-gated Delete action in Movie and Series detail views that removes the item from Jellyfin and optionally instructs Seerr to remove the corresponding Radarr/Sonarr database entry.

**Architecture:** Decode Jellyfin's `Policy.EnableContentDeletion` on `JellyfinUser` so the existing `AppState.activeUser` reactivity carries permission through profile switches. Add a `MediaDeletionService` that fronts `DELETE /Items/{id}` (Jellyfin) and `DELETE /api/v1/media/{seerrId}/file` (Seerr, which proxies to Radarr/Sonarr with `deleteFiles=true`; file-delete is a no-op since Jellyfin already removed the file, but the *arr-entry removal we actually want comes for free). UI is a confirmation sheet with three flavors: single movie, entire series, multi-season select. The Sonarr cascade toggle is disabled for season-level deletes because Jellyseerr's media-delete endpoint only operates at series granularity.

**Tech Stack:** Swift 6, SwiftUI, AppState `@Observable`, existing HTTPClient + Jellyfin/Seerr service stacks.

**Working dir:** `/Users/vincentherbst/Dev/Sodalite`. No engine work — Sodalite-only feature.

**Spec:** `docs/superpowers/specs/2026-05-24-file-management-design.md`

**Verification model:** No unit-test target. Each task verifies via `xcodebuild` for compile. Functional verification is the manual test matrix in Task 11.

---

## Phase 1 — Permission detection

### Task 1: Add `Policy` sub-struct to `JellyfinUser`

**Files:**
- Modify: `Sodalite/Models/Jellyfin/JellyfinUser.swift`

- [ ] **Step 1: Add the nested Policy struct + optional field**

Open `Sodalite/Models/Jellyfin/JellyfinUser.swift`. Replace its contents with:

```swift
import Foundation

struct JellyfinUser: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let serverID: String
    let hasPassword: Bool?
    let primaryImageTag: String?
    /// Server-side policy block. Sparse responses (e.g. `/Users/Public`)
    /// omit it; `/Users/Me` and `/Users/{id}` return it populated. The
    /// File-Management feature only reads `enableContentDeletion` and
    /// `isAdministrator` from here, but the struct decodes both as a
    /// dedicated sub-type so future per-feature flags can land here
    /// without re-touching the call sites.
    let policy: Policy?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverID = "ServerId"
        case hasPassword = "HasPassword"
        case primaryImageTag = "PrimaryImageTag"
        case policy = "Policy"
    }

    struct Policy: Codable, Sendable, Equatable {
        let isAdministrator: Bool
        let enableContentDeletion: Bool

        enum CodingKeys: String, CodingKey {
            case isAdministrator = "IsAdministrator"
            case enableContentDeletion = "EnableContentDeletion"
        }
    }

    /// True when the current user is allowed to delete content. Either
    /// the dedicated `EnableContentDeletion` flag is on, or the user is
    /// an administrator (admins implicitly have all rights in Jellyfin).
    /// Returns false when `policy` hasn't loaded yet, which is a
    /// conservative default for the brief window between session-restore
    /// and the first `getCurrentUser()` call.
    var canDeleteContent: Bool {
        guard let policy = policy else { return false }
        return policy.isAdministrator || policy.enableContentDeletion
    }
}
```

- [ ] **Step 2: Compile**

Run:
```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head
```

Expected: BUILD SUCCEEDED. The existing call sites use `JellyfinUser` as a black box; adding an optional field doesn't break them.

- [ ] **Step 3: Commit + push**

```bash
git add Sodalite/Models/Jellyfin/JellyfinUser.swift
git commit -m "$(cat <<'EOF'
feat(jellyfin): decode user Policy.EnableContentDeletion

Foundation for the upcoming File Management feature. Adds a Policy
sub-struct on JellyfinUser carrying isAdministrator and
enableContentDeletion. Exposes canDeleteContent as a derived
property so the UI permission gate is a single boolean. policy is
optional because sparse Jellyfin user responses (Public, search hints)
omit it; getCurrentUser() returns it populated.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

## Phase 2 — Service layer

### Task 2: Add `deleteItem` endpoint + service method on Jellyfin

**Files:**
- Modify: `Sodalite/Services/Jellyfin/JellyfinEndpoints.swift`
- Modify: `Sodalite/Services/Jellyfin/JellyfinItemService.swift`

- [ ] **Step 1: Add the endpoint case**

Open `Sodalite/Services/Jellyfin/JellyfinEndpoints.swift`. Find the `case unmarkFavorite(userID: String, itemID: String)` near the existing `// Favorites` section (around line 42). Below the `// Items` block (between the existing `case similarItems` line 29 and `// Genres & Studios` line 32), add a new case:

```swift
    /// DELETE /Items/{itemID} — server-side delete. Jellyfin handles
    /// the cascade (series → seasons → episodes) on its own; we call
    /// this once per item.
    case deleteItem(itemID: String)
```

Then in the `path` switch around line 51, add a case for `deleteItem`:

```swift
        case .deleteItem(let itemID):
            "/Items/\(itemID)"
```

In the `method` switch around line 108, extend the `.unmarkFavorite` line to also include `.deleteItem`:

```swift
        case .unmarkFavorite, .deleteItem:
            .delete
```

- [ ] **Step 2: Add the service method**

Open `Sodalite/Services/Jellyfin/JellyfinItemService.swift`. Add to the protocol (around line 9):

```swift
    func deleteItem(itemID: String) async throws
```

Add the implementation in the `final class JellyfinItemService` after the existing `setFavorite` method (around line 59):

```swift
    func deleteItem(itemID: String) async throws {
        try await client.request(endpoint: JellyfinEndpoint.deleteItem(itemID: itemID))
    }
```

- [ ] **Step 3: Compile**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit + push**

```bash
git add Sodalite/Services/Jellyfin/JellyfinEndpoints.swift \
        Sodalite/Services/Jellyfin/JellyfinItemService.swift
git commit -m "$(cat <<'EOF'
feat(jellyfin): add deleteItem service method

Wraps DELETE /Items/{id}. Jellyfin recursively removes children
(seasons + episodes for a series, episodes for a season), so this
single endpoint covers all three deletion scopes the File Management
feature needs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 3: Add `mediaFileDelete` Seerr endpoint + service methods

**Files:**
- Modify: `Sodalite/Services/Seerr/SeerrEndpoints.swift`
- Modify: `Sodalite/Services/Seerr/SeerrMediaService.swift`

- [ ] **Step 1: Add the endpoint case**

Open `Sodalite/Services/Seerr/SeerrEndpoints.swift`. Add to the case list (after `case tvSeasonDetail` around line 25):

```swift
    /// DELETE /api/v1/media/{id}/file — Jellyseerr proxies this to
    /// Radarr's `removeMovie` or Sonarr's `removeSeries`, both invoked
    /// with `deleteFiles: true`. Since Jellyfin already removed the
    /// file before we get here, the file-delete attempt is a no-op
    /// on the *arr side; the database-entry removal is the
    /// side-effect we want. Requires the Seerr user to have the
    /// MANAGE_REQUESTS permission.
    case mediaFileDelete(seerrMediaID: Int)
```

In the `path` switch (around line 37 - 67) add the new case:

```swift
        case .mediaFileDelete(let id): "/api/v1/media/\(id)/file"
```

In the `method` switch (around line 69), extend to include the new case:

```swift
    var method: HTTPMethod {
        switch self {
        case .authJellyfin, .createRequest: .post
        case .authLogout: .post
        case .mediaFileDelete: .delete
        default: .get
        }
    }
```

In `queryItems` (around line 77), add the `is4k=false` parameter at the end of the switch:

```swift
        case .mediaFileDelete:
            // is4k is required by the Jellyseerr endpoint; Sodalite has
            // no 4K-profile distinction in its flow, always false.
            return [URLQueryItem(name: "is4k", value: "false")]
```

- [ ] **Step 2: Add service methods**

Open `Sodalite/Services/Seerr/SeerrMediaService.swift`. Extend the protocol (around line 3):

```swift
protocol SeerrMediaServiceProtocol: Sendable {
    func movieDetail(tmdbID: Int) async throws -> SeerrMovieDetail
    func tvDetail(tmdbID: Int) async throws -> SeerrTVDetail
    func tvSeasonDetail(tmdbID: Int, seasonNumber: Int) async throws -> SeerrSeasonDetail

    /// Removes the Radarr database entry for the movie with the given
    /// TMDB id. Returns true if a Seerr media record was found and the
    /// delete call was made, false if no Seerr record exists (treated
    /// as a successful no-op by the deletion service).
    func removeMovieFromRadarr(tmdbID: Int) async throws -> Bool

    /// Same as `removeMovieFromRadarr` for series.
    func removeSeriesFromSonarr(tmdbID: Int) async throws -> Bool
}
```

Add the implementations after the existing methods:

```swift
    func removeMovieFromRadarr(tmdbID: Int) async throws -> Bool {
        // Resolve TMDB id → Seerr media id. movieDetail returns
        // mediaInfo.id only when Seerr has a record (the movie was
        // requested through Seerr or detected via library scan). If
        // mediaInfo is nil, there's nothing for Seerr to remove.
        let detail = try await movieDetail(tmdbID: tmdbID)
        guard let seerrMediaID = detail.mediaInfo?.id else { return false }
        try await client.request(
            endpoint: SeerrEndpoint.mediaFileDelete(seerrMediaID: seerrMediaID)
        )
        return true
    }

    func removeSeriesFromSonarr(tmdbID: Int) async throws -> Bool {
        let detail = try await tvDetail(tmdbID: tmdbID)
        guard let seerrMediaID = detail.mediaInfo?.id else { return false }
        try await client.request(
            endpoint: SeerrEndpoint.mediaFileDelete(seerrMediaID: seerrMediaID)
        )
        return true
    }
```

- [ ] **Step 3: Compile**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit + push**

```bash
git add Sodalite/Services/Seerr/SeerrEndpoints.swift \
        Sodalite/Services/Seerr/SeerrMediaService.swift
git commit -m "$(cat <<'EOF'
feat(seerr): add removeMovieFromRadarr / removeSeriesFromSonarr

Two composite operations: look up the Seerr media-record by TMDB id
via the existing detail endpoint, then DELETE /api/v1/media/{id}/file
to instruct Jellyseerr to remove the Radarr/Sonarr database entry.
Returns false when no Seerr record exists for the title (manual
library add, never requested through Seerr) so the caller can treat
that as a successful no-op.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 4: Create `MediaDeletionService` + `MediaDeletionError`

**Files:**
- Create: `Sodalite/Services/Deletion/MediaDeletionService.swift`
- Create: `Sodalite/Services/Deletion/MediaDeletionError.swift`

- [ ] **Step 1: Create the error type**

Create `Sodalite/Services/Deletion/MediaDeletionError.swift`:

```swift
import Foundation

/// Surface for failures during a media-deletion flow. The `stage`
/// distinguishes Jellyfin failures (the item was never deleted) from
/// Seerr-cascade failures after Jellyfin already succeeded (the file
/// is gone from the library but the *arr-stack entry still exists).
/// The UI uses this distinction to tell the user whether to retry or
/// to expect orphan state.
struct MediaDeletionError: Error, Sendable {
    enum Stage: Sendable { case jellyfin, seerr }
    let stage: Stage
    let underlying: Error
    /// True when Jellyfin succeeded but Seerr failed afterwards. The
    /// caller surfaces a different toast in that case.
    var partialSuccess: Bool { stage == .seerr }
}
```

- [ ] **Step 2: Create the service**

Create `Sodalite/Services/Deletion/MediaDeletionService.swift`:

```swift
import Foundation

protocol MediaDeletionServiceProtocol: Sendable {
    /// Deletes a movie from Jellyfin. If `cascadeToArrStack` is true,
    /// also instructs Seerr to remove the Radarr entry (no-op if Seerr
    /// has no record for the title).
    func deleteMovie(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws

    /// Deletes an entire series from Jellyfin (cascades to all seasons
    /// + episodes server-side). If `cascadeToArrStack` is true, also
    /// instructs Seerr to remove the Sonarr entry.
    func deleteSeries(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws

    /// Deletes one or more seasons from Jellyfin. The Seerr cascade is
    /// not available at season granularity (Jellyseerr's media-delete
    /// endpoint only operates on the whole series), so
    /// `cascadeToArrStack` is accepted but ignored. The UI prevents the
    /// toggle from being on in this case; the parameter is here for
    /// signature symmetry.
    func deleteSeasons(seasonItemIDs: [String], cascadeToArrStack: Bool) async throws
}

@MainActor
final class MediaDeletionService: MediaDeletionServiceProtocol {
    private let jellyfinItems: any JellyfinItemServiceProtocol
    private let seerrMedia: any SeerrMediaServiceProtocol

    init(
        jellyfinItems: any JellyfinItemServiceProtocol,
        seerrMedia: any SeerrMediaServiceProtocol
    ) {
        self.jellyfinItems = jellyfinItems
        self.seerrMedia = seerrMedia
    }

    func deleteMovie(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws {
        do {
            try await jellyfinItems.deleteItem(itemID: itemID)
        } catch {
            throw MediaDeletionError(stage: .jellyfin, underlying: error)
        }
        guard cascadeToArrStack, let tmdbID = tmdbID else { return }
        do {
            _ = try await seerrMedia.removeMovieFromRadarr(tmdbID: tmdbID)
        } catch {
            throw MediaDeletionError(stage: .seerr, underlying: error)
        }
    }

    func deleteSeries(itemID: String, tmdbID: Int?, cascadeToArrStack: Bool) async throws {
        do {
            try await jellyfinItems.deleteItem(itemID: itemID)
        } catch {
            throw MediaDeletionError(stage: .jellyfin, underlying: error)
        }
        guard cascadeToArrStack, let tmdbID = tmdbID else { return }
        do {
            _ = try await seerrMedia.removeSeriesFromSonarr(tmdbID: tmdbID)
        } catch {
            throw MediaDeletionError(stage: .seerr, underlying: error)
        }
    }

    func deleteSeasons(seasonItemIDs: [String], cascadeToArrStack: Bool) async throws {
        // cascadeToArrStack is intentionally ignored. Jellyseerr's
        // media-delete endpoint only operates at series granularity; if
        // the caller asked for a season-cascade the UI is buggy, but we
        // refuse to silently remove the whole Sonarr series.
        for itemID in seasonItemIDs {
            do {
                try await jellyfinItems.deleteItem(itemID: itemID)
            } catch {
                throw MediaDeletionError(stage: .jellyfin, underlying: error)
            }
        }
    }
}
```

- [ ] **Step 3: Compile**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit + push**

```bash
git add Sodalite/Services/Deletion/
git commit -m "$(cat <<'EOF'
feat(deletion): add MediaDeletionService + MediaDeletionError

Single boundary the detail views call into. deleteMovie / deleteSeries
hit Jellyfin first, then optionally Seerr; deleteSeasons hits Jellyfin
only (the *arr cascade isn't available at season granularity).
MediaDeletionError.partialSuccess flags the case where Jellyfin
succeeded but Seerr failed afterwards, so the UI can render a
different toast.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 5: Wire `MediaDeletionService` into `DependencyContainer`

**Files:**
- Modify: `Sodalite/App/Environment/DependencyContainer.swift`

- [ ] **Step 1: Locate the existing service properties**

Open `Sodalite/App/Environment/DependencyContainer.swift`. Search for where the existing `jellyfinItemService` and `seerrMediaService` are constructed. Run:

```bash
grep -n "jellyfinItemService\|seerrMediaService\|JellyfinItemService(\|SeerrMediaService(" Sodalite/App/Environment/DependencyContainer.swift | head -10
```

Note the line numbers. The exact placement depends on file layout; the goal is to add `mediaDeletionService` right next to where `jellyfinItemService` and `seerrMediaService` are declared/initialised.

- [ ] **Step 2: Add the property**

In the same property block as the other services, add:

```swift
    /// File-deletion service that fronts Jellyfin and Seerr. Used by
    /// MovieDetailView and SeriesDetailView when the active user has
    /// content-deletion rights (see JellyfinUser.canDeleteContent).
    let mediaDeletionService: any MediaDeletionServiceProtocol
```

In the initialiser, where the other services are constructed (after both `jellyfinItemService` and `seerrMediaService` exist), add:

```swift
        self.mediaDeletionService = MediaDeletionService(
            jellyfinItems: jellyfinItemService,
            seerrMedia: seerrMediaService
        )
```

If the file uses property initialisation with `let foo = …` directly (not in an init body), follow that pattern instead. Read 30 lines around the service declarations to match the existing style.

- [ ] **Step 3: Compile**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit + push**

```bash
git add Sodalite/App/Environment/DependencyContainer.swift
git commit -m "$(cat <<'EOF'
feat(deletion): wire MediaDeletionService into DependencyContainer

Constructed once with the existing Jellyfin and Seerr media services,
exposed via DI so detail views can pull it from
@Environment(\.dependencies).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

## Phase 3 — UI

### Task 6: Create `MediaDeletionSheet` (movie variant)

**Files:**
- Create: `Sodalite/Player/UI/MediaDeletionSheet.swift` — wait, wrong place; create at `Sodalite/Features/Detail/MediaDeletionSheet.swift` so it lives next to the detail views that use it.
- Create: `Sodalite/Features/Detail/MediaDeletionSheet.swift`

- [ ] **Step 1: Create the file with movie + series + season variants**

Create `Sodalite/Features/Detail/MediaDeletionSheet.swift`:

```swift
import SwiftUI

/// Confirmation sheet for the File Management feature. One view covers
/// three scopes via the `Mode` enum: a single movie, an entire series,
/// or one or more individually-selected seasons.
///
/// Visibility of the parent Delete button is gated on the active
/// user's `canDeleteContent` property, which already reacts to profile
/// switches (AppState.activeUser is @Observable). The server is the
/// final authority — a 403 from Jellyfin during a stale-policy window
/// surfaces as the standard partial-failure toast.
struct MediaDeletionSheet: View {
    /// Scope of the deletion. The view's body branches on this.
    enum Mode: Equatable {
        case movie(itemID: String, tmdbID: Int?, title: String)
        case series(itemID: String, tmdbID: Int?, title: String, seasons: [SeasonOption])
    }

    /// One row in the series season-picker. `id` is the Jellyfin item id
    /// of the season; `seasonNumber` is the display number, `title` is
    /// the localised "Season 1" / "Specials" string Jellyfin returns.
    struct SeasonOption: Identifiable, Equatable {
        let id: String
        let seasonNumber: Int
        let title: String
    }

    let mode: Mode
    /// Invoked when the user confirms. The closure receives the chosen
    /// cascade flag and (for series) the season selection. The sheet
    /// stays open until the action's async work completes; the parent
    /// is responsible for calling `dismiss()` once it finishes.
    let onConfirm: (DeletionRequest) async -> DeletionOutcome
    @Environment(\.dismiss) private var dismiss

    /// What the parent receives. For movie + entire-series cases the
    /// `seasonItemIDs` array is empty.
    struct DeletionRequest {
        let cascadeToArrStack: Bool
        /// `true` for the series-wide case, `false` for season-level.
        let deleteEntireSeries: Bool
        let seasonItemIDs: [String]
    }

    /// What the parent reports back. The sheet uses this to decide
    /// which toast to show (or none, and dismiss).
    enum DeletionOutcome: Equatable {
        case success
        case partialSuccess(message: String)
        case failure(message: String)
    }

    // MARK: - Local state

    @State private var cascadeToArrStack: Bool = true
    @State private var deleteEntireSeries: Bool = false
    @State private var selectedSeasonIDs: Set<String> = []
    @State private var isDeleting: Bool = false
    @State private var toast: DeletionOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            header

            switch mode {
            case .movie:
                movieBody
            case .series(_, _, _, let seasons):
                seriesBody(seasons: seasons)
            }

            Spacer()

            footer
        }
        .padding(48)
        .frame(maxWidth: 800)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(alignment: .top) {
            if let toast = toast {
                toastView(toast)
                    .padding(.top, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("delete.confirm.title")
                .font(.title2)
                .fontWeight(.semibold)
            Text(titleSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var titleSubtitle: String {
        switch mode {
        case .movie(_, _, let title): return title
        case .series(_, _, let title, _): return title
        }
    }

    private var movieBody: some View {
        VStack(alignment: .leading, spacing: 24) {
            cascadeToggle(disabled: false)
            Text("delete.confirm.movie.body")
                .font(.body)
                .foregroundStyle(.primary)
        }
    }

    private func seriesBody(seasons: [SeasonOption]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: $deleteEntireSeries) {
                Text("delete.confirm.series.entire")
                    .font(.headline)
            }
            .onChange(of: deleteEntireSeries) { _, newValue in
                // Switching to whole-series clears any season selection
                // so the visual state stays coherent.
                if newValue { selectedSeasonIDs.removeAll() }
            }

            seasonList(seasons: seasons)
                .disabled(deleteEntireSeries)
                .opacity(deleteEntireSeries ? 0.4 : 1.0)

            cascadeToggle(disabled: !deleteEntireSeries)
            if !deleteEntireSeries {
                Text("delete.confirm.cascade.seasonsFootnote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func seasonList(seasons: [SeasonOption]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("delete.confirm.series.seasons")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(seasons) { season in
                Button {
                    if selectedSeasonIDs.contains(season.id) {
                        selectedSeasonIDs.remove(season.id)
                    } else {
                        selectedSeasonIDs.insert(season.id)
                    }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: selectedSeasonIDs.contains(season.id)
                            ? "checkmark.square.fill"
                            : "square")
                            .font(.title3)
                        Text(season.title)
                            .font(.body)
                        Spacer()
                    }
                }
                .buttonStyle(.card)
            }
        }
    }

    private func cascadeToggle(disabled: Bool) -> some View {
        Toggle(isOn: $cascadeToArrStack) {
            VStack(alignment: .leading, spacing: 2) {
                Text("delete.confirm.cascade.title")
                Text("delete.confirm.cascade.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1.0)
        .onChange(of: disabled) { _, isDisabled in
            // Force off when disabled so the parent never sees a
            // cascade=true with seasons-only selection.
            if isDisabled { cascadeToArrStack = false }
        }
    }

    private var footer: some View {
        HStack(spacing: 24) {
            Button {
                dismiss()
            } label: {
                Text("common.cancel")
                    .frame(minWidth: 200)
            }
            .buttonStyle(.bordered)
            .disabled(isDeleting)

            Button(role: .destructive) {
                Task { await performDelete() }
            } label: {
                if isDeleting {
                    ProgressView()
                        .frame(minWidth: 200)
                } else {
                    Text("delete.confirm.deleteButton")
                        .frame(minWidth: 200)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isDeleting || !canConfirm)
        }
    }

    private func toastView(_ outcome: DeletionOutcome) -> some View {
        let (text, color): (String, Color) = {
            switch outcome {
            case .success:
                return (String(localized: "delete.toast.success"), .green)
            case .partialSuccess(let msg):
                return (msg, .orange)
            case .failure(let msg):
                return (msg, .red)
            }
        }()
        return Text(text)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(color.opacity(0.85))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    // MARK: - State helpers

    /// True when at least one valid deletion target is selected.
    private var canConfirm: Bool {
        switch mode {
        case .movie:
            return true
        case .series:
            return deleteEntireSeries || !selectedSeasonIDs.isEmpty
        }
    }

    private func performDelete() async {
        isDeleting = true
        defer { isDeleting = false }

        let request = DeletionRequest(
            cascadeToArrStack: cascadeToArrStack,
            deleteEntireSeries: {
                if case .movie = mode { return false }
                return deleteEntireSeries
            }(),
            seasonItemIDs: deleteEntireSeries ? [] : Array(selectedSeasonIDs)
        )
        let outcome = await onConfirm(request)
        toast = outcome
        if case .success = outcome {
            // Brief hold so the user sees the success indicator before
            // the sheet auto-dismisses. Failure / partialSuccess toasts
            // stay until the user presses Cancel.
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        }
    }
}
```

- [ ] **Step 2: Compile**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head
```

Expected: BUILD SUCCEEDED. Localisation warnings about new keys are expected (Task 10 adds them).

- [ ] **Step 3: Commit + push**

```bash
git add Sodalite/Features/Detail/MediaDeletionSheet.swift
git commit -m "$(cat <<'EOF'
feat(detail): MediaDeletionSheet for movie + series + season scopes

One sheet with three modes via an enum. Movie case is a single
cascade-to-Sonarr-or-Radarr toggle. Series case adds a "delete entire
series" toggle plus a per-season checkbox list; the cascade toggle is
forcibly disabled when only individual seasons are selected, with a
footnote explaining why (Jellyseerr's media-delete endpoint can't
target individual seasons). Confirm action runs async, sheet stays
open until success / failure surfaces a toast.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 7: Add Delete button to `MovieDetailView`

**Files:**
- Modify: `Sodalite/Features/Detail/MovieDetailView.swift`

- [ ] **Step 1: Inspect the existing action-row layout**

```bash
grep -n "HStack(spacing: 16)\|playButton\|favoriteButton\|MovieDetailActionButton\|DetailActionButton" Sodalite/Features/Detail/MovieDetailView.swift | head -15
```

Read the surrounding 20 lines of context for whichever button-row pattern this file uses. The existing buttons (Play, Favorite) are likely placed inside an HStack near line 182 according to the earlier grep. Match that pattern.

- [ ] **Step 2: Add the gating + sheet state**

Inside the `MovieDetailView` struct, add (near the other `@State` / `@FocusState` declarations near the top):

```swift
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @State private var isPresentingDeleteSheet: Bool = false

    /// True when the active user has Jellyfin's EnableContentDeletion
    /// flag (or is an administrator). Read reactively from
    /// AppState.activeUser, so a profile switch updates the visibility
    /// without a manual refresh.
    private var canDelete: Bool {
        appState.activeUser?.canDeleteContent == true
    }
```

If `@Environment(\.appState)` and `@Environment(\.dependencies)` are already declared in this file, do not duplicate; reuse the existing ones.

- [ ] **Step 3: Add the Delete button to the action row**

In the HStack at line 182 (or wherever the Play / Favorite buttons sit), append after the existing buttons:

```swift
                if canDelete {
                    Button(role: .destructive) {
                        isPresentingDeleteSheet = true
                    } label: {
                        Label("detail.delete.button", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
```

- [ ] **Step 4: Add the sheet presentation**

At the end of the outermost view's body chain (after any existing `.sheet`, `.fullScreenCover` modifiers, before the `.background` modifier if any), add:

```swift
        .sheet(isPresented: $isPresentingDeleteSheet) {
            // The detail view model owns the JellyfinItem we're deleting;
            // tmdbID is pulled from item.providerIds via the existing
            // helper. If the helper isn't directly available here, grab
            // it from the vm.
            let item = vm.item
            let tmdbID = item.tmdbID  // existing helper; verify by grep below
            MediaDeletionSheet(
                mode: .movie(
                    itemID: item.id,
                    tmdbID: tmdbID,
                    title: item.name
                ),
                onConfirm: { request in
                    do {
                        try await dependencies.mediaDeletionService.deleteMovie(
                            itemID: item.id,
                            tmdbID: tmdbID,
                            cascadeToArrStack: request.cascadeToArrStack
                        )
                        // Successful delete: pop the detail view.
                        // Existing dismiss pattern is environment-based.
                        // See SeriesDetailView for the analogous flow.
                        return .success
                    } catch let error as MediaDeletionError {
                        if error.partialSuccess {
                            return .partialSuccess(
                                message: String(localized: "delete.toast.partialSuccess")
                            )
                        } else {
                            return .failure(
                                message: String(localized: "delete.toast.failure")
                            )
                        }
                    } catch {
                        return .failure(
                            message: String(localized: "delete.toast.failure")
                        )
                    }
                }
            )
        }
```

The `tmdbID` accessor — verify it exists. Run:

```bash
grep -n "tmdbID\|tmdbId\|providerIds" Sodalite/Models/Jellyfin/JellyfinItem.swift | head
```

If `JellyfinItem.tmdbID` doesn't exist as a computed property, look for `providerIds` (the raw map) and extract via `providerIds?["Tmdb"]` then `Int(...)`. Use whichever the codebase already does (project memory notes a "TMDB ID Extraction with Case-Insensitive Fallback" helper — likely `item.tmdbID` or `JellyfinItem.extractTMDBID(from:)`).

After successful delete, the detail view should pop. If `MovieDetailView` is mounted via `NavigationStack` or a sheet, the dismiss happens via `@Environment(\.dismiss)`. Add at the top:

```swift
    @Environment(\.dismiss) private var dismiss
```

And in the `onConfirm` success case, instead of just returning `.success`, do:

```swift
                    try await dependencies.mediaDeletionService.deleteMovie(
                        itemID: item.id,
                        tmdbID: tmdbID,
                        cascadeToArrStack: request.cascadeToArrStack
                    )
                    // Pop the detail view after the sheet's own
                    // success-toast hold completes. Use a task delay so
                    // the toast is visible.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1100))
                        dismiss()
                    }
                    return .success
```

- [ ] **Step 5: Compile**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head
```

Expected: BUILD SUCCEEDED. If `mediaDeletionService` isn't yet reachable through `dependencies`, that's a Task 5 problem — go back and verify.

- [ ] **Step 6: Commit + push**

```bash
git add Sodalite/Features/Detail/MovieDetailView.swift
git commit -m "$(cat <<'EOF'
feat(detail): Delete button on MovieDetailView

Gated on JellyfinUser.canDeleteContent so it appears for admins and
EnableContentDeletion-enabled users, and disappears on a profile
switch to a regular user via the existing AppState.activeUser
@Observable. Tapping it presents the MediaDeletionSheet with a movie
mode; success dismisses the detail view after the toast settles.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 8: Add Delete button to `SeriesDetailView`

**Files:**
- Modify: `Sodalite/Features/Detail/SeriesDetailView.swift`

- [ ] **Step 1: Inspect the existing chrome**

```bash
grep -n "HStack\|playButton\|favoriteButton\|@State\|@Environment\|seasons:" Sodalite/Features/Detail/SeriesDetailView.swift | head -25
```

Locate where the Play button sits in the series chrome.

- [ ] **Step 2: Add gating + sheet state**

Inside the struct, add the same environment + state declarations as in Task 7's Step 2 (skip any that already exist):

```swift
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var isPresentingDeleteSheet: Bool = false

    private var canDelete: Bool {
        appState.activeUser?.canDeleteContent == true
    }
```

- [ ] **Step 3: Add the Delete button**

Append the same Delete button next to the series's Play button:

```swift
                if canDelete {
                    Button(role: .destructive) {
                        isPresentingDeleteSheet = true
                    } label: {
                        Label("detail.delete.button", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
```

- [ ] **Step 4: Build the season options for the sheet**

In the body, before the `.sheet(...)` modifier, compute the season options from whatever season state the view already maintains. SeriesDetailView already drives season-tabs from a `[JellyfinItem]` of season items; map them to `SeasonOption`:

```swift
    private func deletionSeasonOptions(from seasons: [JellyfinItem]) -> [MediaDeletionSheet.SeasonOption] {
        seasons.map { season in
            MediaDeletionSheet.SeasonOption(
                id: season.id,
                seasonNumber: season.indexNumber ?? 0,
                title: season.name
            )
        }
    }
```

Verify the season-loading variable name by reading the file around line 22-50 (the focus-state and season-tracking section). If the view stores seasons in `vm.seasons` or `viewModel.seasonItems`, adjust accordingly.

- [ ] **Step 5: Add the sheet presentation**

At the end of the body (alongside any existing `.sheet`), add:

```swift
        .sheet(isPresented: $isPresentingDeleteSheet) {
            let item = vm.item
            let tmdbID = item.tmdbID
            MediaDeletionSheet(
                mode: .series(
                    itemID: item.id,
                    tmdbID: tmdbID,
                    title: item.name,
                    seasons: deletionSeasonOptions(from: vm.seasons)
                ),
                onConfirm: { request in
                    do {
                        if request.deleteEntireSeries {
                            try await dependencies.mediaDeletionService.deleteSeries(
                                itemID: item.id,
                                tmdbID: tmdbID,
                                cascadeToArrStack: request.cascadeToArrStack
                            )
                        } else {
                            try await dependencies.mediaDeletionService.deleteSeasons(
                                seasonItemIDs: request.seasonItemIDs,
                                cascadeToArrStack: false
                            )
                        }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(1100))
                            // Only dismiss if the whole series was deleted.
                            // For seasons-only deletion the user might still
                            // want to view the series.
                            if request.deleteEntireSeries { dismiss() }
                        }
                        return .success
                    } catch let error as MediaDeletionError {
                        if error.partialSuccess {
                            return .partialSuccess(
                                message: String(localized: "delete.toast.partialSuccess")
                            )
                        } else {
                            return .failure(
                                message: String(localized: "delete.toast.failure")
                            )
                        }
                    } catch {
                        return .failure(
                            message: String(localized: "delete.toast.failure")
                        )
                    }
                }
            )
        }
```

The exact view-model accessor (`vm.item`, `vm.seasons`) depends on the file's naming. Replace with the actual names you find. If the season-list state isn't directly accessible (e.g. it lives in a Combine subscription and isn't published synchronously), pull it from the view model the same way the season-tab-row reads it.

- [ ] **Step 6: Compile**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit + push**

```bash
git add Sodalite/Features/Detail/SeriesDetailView.swift
git commit -m "$(cat <<'EOF'
feat(detail): Delete button + sheet on SeriesDetailView

Same canDelete gate as the movie variant. The sheet handles three
sub-flows: whole-series delete (Jellyfin + optional Sonarr cleanup),
single-season delete, multi-season delete. Season-level deletes never
trigger the Sonarr cascade because Jellyseerr can only remove entire
series; the sheet disables the cascade toggle in that mode.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 9: Library cache invalidation after successful delete

**Files:**
- Modify: `Sodalite/Features/Detail/MovieDetailView.swift`
- Modify: `Sodalite/Features/Detail/SeriesDetailView.swift`

The library / home views cache results. Without invalidation, a deleted item still appears until the cache evicts naturally.

- [ ] **Step 1: Find the cache surface**

```bash
grep -rn "FilterCache\|invalidate\|libraryCache\|clearCache" Sodalite/Services/Cache/ Sodalite/Features/Library/ 2>/dev/null | head -10
```

Identify the existing invalidation pattern (likely `FilterCache.clear()` or `dependencies.filterCache.invalidate()`).

- [ ] **Step 2: Hook invalidation into both detail views' success paths**

In `MovieDetailView.swift` and `SeriesDetailView.swift`, in the `onConfirm` success branch (after the `try await dependencies.mediaDeletionService.delete…` call, before `return .success`), add:

```swift
                        dependencies.filterCache.invalidate()
                        // The home screen's continueWatching / nextUp /
                        // latestMedia rows cache from the same axis. They
                        // re-fetch on focus, so popping back to root after
                        // delete will redraw them with the item gone.
```

The exact method name + accessor may differ — match what `grep` shows you. If the cache is on `AppState` instead of `DependencyContainer`, use that.

- [ ] **Step 3: Compile + commit + push**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head

git add Sodalite/Features/Detail/MovieDetailView.swift \
        Sodalite/Features/Detail/SeriesDetailView.swift
git commit -m "$(cat <<'EOF'
feat(detail): invalidate library cache after successful delete

Without this the deleted item lingers in the library / home rows until
the cache evicts naturally, which can be tens of minutes. Invalidating
on the success branch of the delete sheet means the user's next visit
to the library re-fetches and the gap shows immediately.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 10: Localisation keys (all 26 locales)

**Files:**
- Modify: `Sodalite/Localizable.xcstrings`

- [ ] **Step 1: Catalogue the new keys**

The keys introduced by Tasks 6 - 9:

```
detail.delete.button
delete.confirm.title
delete.confirm.movie.body
delete.confirm.series.entire
delete.confirm.series.seasons
delete.confirm.cascade.title
delete.confirm.cascade.subtitle
delete.confirm.cascade.seasonsFootnote
delete.confirm.deleteButton
delete.toast.success
delete.toast.partialSuccess
delete.toast.failure
common.cancel    (verify if already exists; reuse if so)
```

Run:

```bash
grep -n '"common.cancel"' Sodalite/Localizable.xcstrings | head
```

If `common.cancel` exists, drop it from the new-keys list.

- [ ] **Step 2: Suggested EN + DE values**

| Key | EN | DE |
|-----|----|----|
| detail.delete.button | Delete | Löschen |
| delete.confirm.title | Confirm Deletion | Löschen bestätigen |
| delete.confirm.movie.body | This will permanently remove the file from your Jellyfin server. | Die Datei wird dauerhaft vom Jellyfin-Server entfernt. |
| delete.confirm.series.entire | Delete entire series | Komplette Serie löschen |
| delete.confirm.series.seasons | Seasons | Staffeln |
| delete.confirm.cascade.title | Also remove from Radarr / Sonarr | Auch aus Radarr / Sonarr entfernen |
| delete.confirm.cascade.subtitle | Removes the entry so the *arr stack stops monitoring it. | Entfernt den Eintrag, damit der *arr-Stack die Datei nicht erneut herunterlädt. |
| delete.confirm.cascade.seasonsFootnote | Radarr / Sonarr can only remove the entire series, not individual seasons. To also clean up the *arr stack, delete the whole series. | Radarr / Sonarr kann nur die komplette Serie entfernen, keine einzelnen Staffeln. Um auch im *arr-Stack aufzuräumen, lösche die ganze Serie. |
| delete.confirm.deleteButton | Delete | Löschen |
| delete.toast.success | Deleted. | Gelöscht. |
| delete.toast.partialSuccess | Removed from Jellyfin, but the Radarr / Sonarr entry could not be removed. | Aus Jellyfin entfernt, aber der Eintrag in Radarr / Sonarr konnte nicht entfernt werden. |
| delete.toast.failure | Failed to delete. The library is unchanged. | Löschen fehlgeschlagen. Die Bibliothek ist unverändert. |
| common.cancel | Cancel | Abbrechen |

For the other 24 locales (`cs, da, el, es, fi, fr, hr, hu, it, ja, ko, nb, nl, pl, pt-BR, pt-PT, ro, ru, sk, sv, tr, uk, zh-Hans, zh-Hant`), translate each value into a natural, short form. For technical terms like "Radarr", "Sonarr", "Jellyfin", do not translate — they are product names. Match the style of the existing translated keys in this file (e.g. `player.stats.title` is translated across all 26 locales already).

- [ ] **Step 3: Splice + normalise spacing**

Match Xcode's exact format. After splicing, run:

```bash
sed -i '' 's/"\([^"]*\)": {/"\1" : {/g' Sodalite/Localizable.xcstrings
```

- [ ] **Step 4: Validate + build**

```bash
python3 -c "import json; json.load(open('Sodalite/Localizable.xcstrings'))" && echo "JSON OK"
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head
git diff --stat
```

Expected: JSON OK, BUILD SUCCEEDED. Diff should be ~2,000 - 3,000 lines (13 keys × 26 locales × ~6 lines). If it explodes to 30k, fix spacing with the sed above.

- [ ] **Step 5: Commit + push**

```bash
git add Sodalite/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
i18n(deletion): localise File Management UI in all 26 languages

13 new keys covering the Delete button, confirmation sheet (movie +
series + cascade footnote), and the three toast outcomes. Product
names (Radarr, Sonarr, Jellyfin) are not translated. Style matches
existing player.stats.* + detail.tech.* entries.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

## Phase 4 — Manual verification

### Task 11: Run the verification matrix on a device

Codebase has no test target. All verification is manual on an Apple TV (or simulator with a connected Jellyfin + Jellyseerr server).

**Prerequisites:**
- A Jellyfin server reachable from the test device with at least one movie + one series + a Radarr/Sonarr stack behind Jellyseerr.
- Two Jellyfin user accounts on that server:
  - **User A:** Administrator (or has `EnableContentDeletion = true`).
  - **User B:** Regular user (`EnableContentDeletion = false`).

**Test movies / series:** Pick safe candidates you can actually re-download — small files, nothing irreplaceable.

#### Permission gating

- [ ] **Step 1: User B sees no Delete button**

Log in as User B on the device. Open any movie detail. Confirm there is no Delete button next to Play. Open any series detail. Confirm the same.

- [ ] **Step 2: User A sees the Delete button**

Log in as User A. Open a movie detail. Confirm a red Delete button is present in the action row. Open a series detail. Confirm the same.

#### Profile switching

- [ ] **Step 3: Profile switch hides the Delete button live**

Still as User A, open a movie detail. Confirm Delete is visible. Return to the launch profile picker and switch to User B. Re-open the same movie detail. Confirm the Delete button is **gone**. No app restart needed.

- [ ] **Step 4: Profile switch back restores the button**

Switch back to User A. Re-open the detail. Confirm Delete is visible again.

#### Movie delete, no cascade

- [ ] **Step 5: Pick a movie that exists in Radarr**

Note the Radarr entry. Open the movie detail in Sodalite (User A). Press Delete. Sheet opens with "Also remove from Radarr / Sonarr" toggle ON by default. **Turn it OFF.** Press Delete. Wait for the success toast and auto-dismiss.

Expected:
- Jellyfin no longer has the movie.
- The file is gone from disk (verify via server SSH or web UI).
- Radarr **still** has the movie entry (verify via Radarr UI).
- Sodalite's library no longer shows the movie.

#### Movie delete, with cascade

- [ ] **Step 6: Delete a different movie with cascade ON**

Open another movie. Press Delete. Leave the toggle ON. Confirm.

Expected:
- Jellyfin: gone.
- File: gone.
- Radarr: entry gone (the movie should NOT appear in Radarr's movie list anymore).

#### Series delete, full

- [ ] **Step 7: Delete an entire series with cascade**

Open a series. Press Delete. In the sheet, toggle "Delete entire series" ON. Confirm the cascade toggle becomes enabled and is ON by default. Press Delete.

Expected:
- Jellyfin: series + all seasons + all episodes gone.
- Sonarr: series entry gone.

#### Series delete, season-level

- [ ] **Step 8: Delete two seasons of a series**

Open another series (or restore one). Press Delete. Leave "Delete entire series" OFF. Tick two seasons. Confirm the cascade toggle is **disabled and shows a footnote** explaining Sonarr can only remove the whole series. Press Delete.

Expected:
- Jellyfin: those two seasons (and their episodes) gone.
- Sonarr: series entry **unchanged** (still has all seasons monitored).
- Sodalite's series detail re-renders with the remaining seasons.

#### Library refresh

- [ ] **Step 9: Library re-renders without the deleted items**

After Step 5 and Step 6, return to the library. Confirm the deleted movies are not in any visible row (Continue Watching, Latest, the relevant library grid).

#### Network failure

- [ ] **Step 10: Force a partial-success state**

Pick a movie that has both a Jellyfin entry and a Radarr entry. Disconnect the device from the network on the Jellyseerr side specifically (e.g. block Jellyseerr's host in router rules, or just turn off Jellyseerr while leaving Jellyfin reachable). Try to delete the movie with cascade ON.

Expected:
- Jellyfin delete succeeds.
- Seerr call fails.
- Sheet shows a partial-success toast: "Removed from Jellyfin, but the Radarr / Sonarr entry could not be removed."
- The sheet does NOT auto-dismiss; user has to press Cancel.

Restore the Jellyseerr connection after this test.

#### Stale-permission handling

- [ ] **Step 11: Server-side permission change mid-session**

Log in as User A. Open a movie detail with the Delete button visible. Without leaving Sodalite, log into Jellyfin's admin web UI on a phone or laptop. Edit User A's policy: turn off `EnableContentDeletion`. Save.

Back in Sodalite (still on User A, button still visible because the UI hasn't refreshed), press Delete. Confirm.

Expected:
- Jellyfin returns 403.
- Sheet shows the failure toast.
- The local library state is unchanged.

#### Cold launch + session restore

- [ ] **Step 12: Restart the app**

Force-quit Sodalite. Re-launch. The session should restore to User A. Open a movie detail. Confirm the Delete button shows (after the brief moment where it might be hidden during initial `getCurrentUser()`). Cancel out — no actual delete needed.

---

## Self-Review

After the plan write, reviewed against the spec:

**Spec coverage:**
- Motivation, scope ✓ (covered by Tasks 7 - 8 + 9)
- Permission detection ✓ (Task 1)
- Service layer (Jellyfin delete + Seerr cascade) ✓ (Tasks 2, 3)
- MediaDeletionService ✓ (Task 4 + 5)
- UI sheet ✓ (Task 6)
- Detail-view integration ✓ (Tasks 7, 8)
- Library invalidation ✓ (Task 9)
- Localisation ✓ (Task 10)
- Reactivity across profile switches ✓ (Task 7 / 8 use `appState.activeUser`, verification Task 11 Step 3 - 4)
- Per-season cascade asymmetry ✓ (Task 4's `deleteSeasons` ignores the parameter, Task 6 disables the toggle, Task 11 Step 8 verifies)
- Partial-success handling ✓ (Task 4 surfaces it via `MediaDeletionError.partialSuccess`, Task 11 Step 10 verifies)
- Manual verification matrix ✓ (Task 11, 12 numbered steps)

**Placeholder scan:** Clean.

**Type consistency:** `MediaDeletionService` / `MediaDeletionServiceProtocol` / `MediaDeletionError` / `MediaDeletionError.Stage` consistent across tasks. `JellyfinUser.Policy` / `JellyfinUser.canDeleteContent` consistent. `MediaDeletionSheet.Mode` / `MediaDeletionSheet.SeasonOption` / `MediaDeletionSheet.DeletionRequest` / `MediaDeletionSheet.DeletionOutcome` all defined in Task 6 and used unchanged in Tasks 7 + 8.

No outstanding gaps.
