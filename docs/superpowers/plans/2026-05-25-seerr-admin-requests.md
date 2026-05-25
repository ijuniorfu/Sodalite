# Seerr Admin Requests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface a permission-gated "Alle Anfragen" admin queue as a third Catalog sub-tab so an authorised Seerr user can approve, decline, delete, and edit (target server / profile / root folder / seasons) any request without leaving Sodalite.

**Architecture:** Extend `SeerrUser` with the Jellyseerr permissions bitfield decoded from `auth/me`. Add five admin methods to `SeerrRequestService` (`allRequests`, `approveRequest`, `declineRequest`, `deleteRequest`, `updateRequest`). Build a new `CatalogAllRequestsView` mirroring the existing `CatalogMyRequestsView` structure plus filter chips + row-level action buttons + a modal Edit sheet. Permission gate lives on `AppState.activeSeerrUser.canManageRequests`, the same reactivity used elsewhere for live UI updates.

**Tech Stack:** Swift 6, SwiftUI, `@Observable` view models, existing `HTTPClient` + `SeerrClient` + `SeerrEndpoint` enum-based service stack.

**Working dir:** `/Users/vincentherbst/Dev/Sodalite`. No engine work — Sodalite-only feature. No external dependencies added.

**Spec:** `docs/superpowers/specs/2026-05-25-seerr-admin-requests-design.md`

**Verification model:** No unit-test target. Each task verifies via `xcodebuild` for compile. Functional verification is the manual test matrix in Task 22.

**UI rules in this codebase (verify on every new focusable / tinted view):** see memory `feedback_sodalite_ui_focus_and_tint`. Three rules: (1) always read tint via `.tint` ShapeStyle, never `Color.accentColor` (the asset is hardcoded blue); (2) custom focusable rows over material use `.focusable(true) + .onLongPressGesture(minimumDuration: 0.01)`, not `Button`; (3) focused fills tinted, not white over material. Canonical pattern: `ValuePickerRow` in `PlaybackSettingsView.swift`.

---

## Phase 1 — Permission detection

### Task 1: Add `permissions` field to `SeerrUser`

**Files:**
- Modify: `Sodalite/Models/Seerr/SeerrUser.swift`

- [ ] **Step 1: Add the optional bitfield**

Replace the contents of `Sodalite/Models/Seerr/SeerrUser.swift` with:

```swift
import Foundation

struct SeerrUser: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let email: String?
    let username: String?
    let displayName: String?
    let avatar: String?
    let userType: Int?
    let requestCount: Int?
    /// Jellyseerr permissions bitfield, decoded from `/api/v1/auth/me`.
    /// Optional because older Jellyseerr installs (pre-1.x) may omit it,
    /// and any cached `SeerrUser` snapshots stored before this field was
    /// introduced (in `RememberedSeerrSession`) ship without it. Default
    /// treatment when nil: no admin rights. See `SeerrPermissions` for
    /// the bit values; use `canManageRequests` for the only check we
    /// actually surface in UI today.
    let permissions: Int?

    var resolvedDisplayName: String {
        displayName ?? username ?? email ?? "User \(id)"
    }
}
```

- [ ] **Step 2: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Models/Seerr/SeerrUser.swift
git commit -m "feat(seerr): decode permissions bitfield on SeerrUser"
```

---

### Task 2: Create `SeerrPermissions` OptionSet + canManageRequests helper

**Files:**
- Create: `Sodalite/Models/Seerr/SeerrPermissions.swift`

- [ ] **Step 1: Add the OptionSet + helper**

Create `Sodalite/Models/Seerr/SeerrPermissions.swift`:

```swift
import Foundation

/// Jellyseerr permissions bitfield. Mirrors the subset of
/// `server/lib/permissions.ts` we actually need to check on the
/// client. Adding new bits as more admin features land is a one-line
/// change — don't enumerate the full set today (YAGNI; Jellyseerr has
/// 30+ bits, and the build can't catch a typo in a value we don't
/// reference).
struct SeerrPermissions: OptionSet, Sendable {
    let rawValue: Int

    static let none           = SeerrPermissions(rawValue: 0)
    static let admin          = SeerrPermissions(rawValue: 2)
    static let manageSettings = SeerrPermissions(rawValue: 4)
    static let manageUsers    = SeerrPermissions(rawValue: 8)
    static let manageRequests = SeerrPermissions(rawValue: 16)
    static let request        = SeerrPermissions(rawValue: 32)
    static let autoApprove    = SeerrPermissions(rawValue: 256)
}

extension SeerrUser {
    /// Admin-feature gate. `ADMIN` bit implicitly grants every
    /// permission per Jellyseerr's evaluator, so we OR the two checks.
    /// Returns false when `permissions == nil`, which happens for
    /// cached sessions written before the field was decoded.
    var canManageRequests: Bool {
        let mask = SeerrPermissions(rawValue: permissions ?? 0)
        return mask.contains(.admin) || mask.contains(.manageRequests)
    }
}
```

- [ ] **Step 2: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Models/Seerr/SeerrPermissions.swift
git commit -m "feat(seerr): SeerrPermissions OptionSet + canManageRequests helper"
```

---

## Phase 2 — Network layer

### Task 3: Create `SeerrRequestFilter` enum

**Files:**
- Create: `Sodalite/Models/Seerr/SeerrRequestFilter.swift`

- [ ] **Step 1: Add the filter**

Create `Sodalite/Models/Seerr/SeerrRequestFilter.swift`:

```swift
import Foundation

/// Status filter for the admin `GET /api/v1/request` endpoint. The
/// raw values are the literal query-string values Jellyseerr accepts
/// (verified against `server/routes/request.ts` mapStatusToTypes).
/// `.all` is the no-filter case Jellyseerr documents as the default.
enum SeerrRequestFilter: String, Codable, Sendable, CaseIterable, Identifiable {
    case pending  = "pending"
    case approved = "approved"
    case declined = "declined"
    case all      = "all"

    var id: String { rawValue }
}
```

- [ ] **Step 2: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Models/Seerr/SeerrRequestFilter.swift
git commit -m "feat(seerr): SeerrRequestFilter enum for admin request list"
```

---

### Task 4: Create `SeerrRequestUpdateBody`

**Files:**
- Create: `Sodalite/Models/Seerr/SeerrRequestUpdateBody.swift`

- [ ] **Step 1: Add the update body**

Create `Sodalite/Models/Seerr/SeerrRequestUpdateBody.swift`:

```swift
import Foundation

/// PUT body for `/api/v1/request/{id}`. Every field is optional;
/// Jellyseerr accepts partial bodies and ignores nil fields. The
/// Edit sheet computes a diff against the original `SeerrRequest`
/// before constructing this, so only changed fields are sent.
///
/// `seasons` is the absolute new set (not a delta), matching the
/// request-create body shape. For movies it stays nil.
///
/// `userId` reassignment isn't surfaced in UI today but the field is
/// included so a future "transfer request" feature can reuse the
/// same body without re-modelling.
struct SeerrRequestUpdateBody: Encodable, Sendable {
    let serverId: Int?
    let profileId: Int?
    let rootFolder: String?
    let languageProfileId: Int?
    let seasons: [Int]?
    let userId: Int?

    init(
        serverId: Int? = nil,
        profileId: Int? = nil,
        rootFolder: String? = nil,
        languageProfileId: Int? = nil,
        seasons: [Int]? = nil,
        userId: Int? = nil
    ) {
        self.serverId = serverId
        self.profileId = profileId
        self.rootFolder = rootFolder
        self.languageProfileId = languageProfileId
        self.seasons = seasons
        self.userId = userId
    }
}
```

- [ ] **Step 2: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Models/Seerr/SeerrRequestUpdateBody.swift
git commit -m "feat(seerr): SeerrRequestUpdateBody for PUT /api/v1/request/:id"
```

---

### Task 5: Add admin endpoint cases to `SeerrEndpoint`

**Files:**
- Modify: `Sodalite/Services/Seerr/SeerrEndpoints.swift`

- [ ] **Step 1: Add cases**

In `Sodalite/Services/Seerr/SeerrEndpoints.swift`, immediately after the existing `case myRequests(userID: Int, take: Int, skip: Int)` line, insert:

```swift
    /// GET /api/v1/request — admin view, all users' requests.
    /// `filter` is the status filter; Jellyseerr also accepts
    /// `unavailable` and `available` but we don't surface those.
    /// Requires the caller to have MANAGE_REQUESTS or ADMIN.
    case allRequests(filter: SeerrRequestFilter, take: Int, skip: Int)
    /// POST /api/v1/request/:id/approve — flips a pending request
    /// to approved, sends it to Radarr/Sonarr. 200 with the updated
    /// SeerrRequest body. 403 if caller lacks MANAGE_REQUESTS.
    case approveRequest(requestID: Int)
    /// POST /api/v1/request/:id/decline — flips a pending request
    /// to declined. Same response shape as approve.
    case declineRequest(requestID: Int)
    /// DELETE /api/v1/request/:id — removes the request entry. Does
    /// not delete the media file if already downloaded.
    case deleteRequest(requestID: Int)
    /// PUT /api/v1/request/:id — modify target server / profile /
    /// root folder / seasons. Partial body, only changed fields sent.
    case updateRequest(requestID: Int, body: SeerrRequestUpdateBody)
```

- [ ] **Step 2: Add path cases**

In the same file, in the `var path: String` switch, add five lines right after the `case .myRequests` line:

```swift
        case .allRequests: "/api/v1/request"
        case .approveRequest(let id): "/api/v1/request/\(id)/approve"
        case .declineRequest(let id): "/api/v1/request/\(id)/decline"
        case .deleteRequest(let id): "/api/v1/request/\(id)"
        case .updateRequest(let id, _): "/api/v1/request/\(id)"
```

- [ ] **Step 3: Add method cases**

In the `var method: HTTPMethod` switch, replace the body with:

```swift
    var method: HTTPMethod {
        switch self {
        case .authJellyfin, .createRequest: .post
        case .authLogout: .post
        case .mediaFileDelete, .deleteRequest: .delete
        case .approveRequest, .declineRequest: .post
        case .updateRequest: .put
        default: .get
        }
    }
```

- [ ] **Step 4: Add query items for `allRequests`**

In the `var queryItems: [URLQueryItem]?` switch, immediately after the `.myRequests` case block, insert:

```swift
        case .allRequests(let filter, let take, let skip):
            return [
                URLQueryItem(name: "take", value: String(take)),
                URLQueryItem(name: "skip", value: String(skip)),
                URLQueryItem(name: "filter", value: filter.rawValue),
                URLQueryItem(name: "sort", value: "added"),
            ]
```

- [ ] **Step 5: Add body case for `updateRequest`**

In the `var body: (any Encodable & Sendable)?` switch, replace its body with:

```swift
    var body: (any Encodable & Sendable)? {
        switch self {
        case .authJellyfin(let body): body
        case .createRequest(let body): body
        case .updateRequest(_, let body): body
        default: nil
        }
    }
```

- [ ] **Step 6: Verify HTTPMethod.put exists**

Run: `grep -n "case put\|case delete" Sodalite/Services/Networking/HTTPMethod.swift`
Expected: both `case put = "PUT"` and `case delete = "DELETE"` present. If `put` is missing, add it to that file (open `Sodalite/Services/Networking/HTTPMethod.swift` and add `case put = "PUT"` to the enum).

- [ ] **Step 7: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add Sodalite/Services/Seerr/SeerrEndpoints.swift Sodalite/Services/Networking/HTTPMethod.swift
git commit -m "feat(seerr): admin request endpoints (allRequests, approve, decline, delete, update)"
```

---

### Task 6: Extend `SeerrRequestService` with admin methods

**Files:**
- Modify: `Sodalite/Services/Seerr/SeerrRequestService.swift`

- [ ] **Step 1: Replace the file**

Replace the contents of `Sodalite/Services/Seerr/SeerrRequestService.swift` with:

```swift
import Foundation

protocol SeerrRequestServiceProtocol: Sendable {
    func createRequest(
        mediaType: SeerrMediaType,
        tmdbID: Int,
        seasons: [Int]?,
        serverID: Int?,
        profileID: Int?,
        rootFolder: String?,
        languageProfileID: Int?,
        tags: [Int]?
    ) async throws -> SeerrRequest

    func myRequests(userID: Int, take: Int, skip: Int) async throws -> SeerrRequestsResult

    /// Admin queue: every request across every user, filtered by
    /// status. Requires the caller to have MANAGE_REQUESTS or ADMIN
    /// in their `SeerrUser.permissions` bitfield. 403 surfaces as
    /// `APIError.unauthorized` if the server-side permission was
    /// revoked between login and the call.
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

@MainActor
final class SeerrRequestService: SeerrRequestServiceProtocol {
    private let client: SeerrClient

    init(client: SeerrClient) {
        self.client = client
    }

    func createRequest(
        mediaType: SeerrMediaType,
        tmdbID: Int,
        seasons: [Int]? = nil,
        serverID: Int? = nil,
        profileID: Int? = nil,
        rootFolder: String? = nil,
        languageProfileID: Int? = nil,
        tags: [Int]? = nil
    ) async throws -> SeerrRequest {
        let body = SeerrCreateRequestBody(
            mediaType: mediaType,
            mediaId: tmdbID,
            seasons: seasons,
            serverId: serverID,
            profileId: profileID,
            rootFolder: rootFolder,
            languageProfileId: languageProfileID,
            tags: tags
        )
        return try await client.request(
            endpoint: SeerrEndpoint.createRequest(body: body),
            responseType: SeerrRequest.self
        )
    }

    func myRequests(userID: Int, take: Int = 50, skip: Int = 0) async throws -> SeerrRequestsResult {
        try await client.request(
            endpoint: SeerrEndpoint.myRequests(userID: userID, take: take, skip: skip),
            responseType: SeerrRequestsResult.self
        )
    }

    func allRequests(
        filter: SeerrRequestFilter,
        take: Int = 50,
        skip: Int = 0
    ) async throws -> SeerrRequestsResult {
        try await client.request(
            endpoint: SeerrEndpoint.allRequests(filter: filter, take: take, skip: skip),
            responseType: SeerrRequestsResult.self
        )
    }

    @discardableResult
    func approveRequest(requestID: Int) async throws -> SeerrRequest {
        try await client.request(
            endpoint: SeerrEndpoint.approveRequest(requestID: requestID),
            responseType: SeerrRequest.self
        )
    }

    @discardableResult
    func declineRequest(requestID: Int) async throws -> SeerrRequest {
        try await client.request(
            endpoint: SeerrEndpoint.declineRequest(requestID: requestID),
            responseType: SeerrRequest.self
        )
    }

    func deleteRequest(requestID: Int) async throws {
        try await client.request(
            endpoint: SeerrEndpoint.deleteRequest(requestID: requestID)
        )
    }

    @discardableResult
    func updateRequest(
        requestID: Int,
        body: SeerrRequestUpdateBody
    ) async throws -> SeerrRequest {
        try await client.request(
            endpoint: SeerrEndpoint.updateRequest(requestID: requestID, body: body),
            responseType: SeerrRequest.self
        )
    }
}
```

- [ ] **Step 2: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Services/Seerr/SeerrRequestService.swift
git commit -m "feat(seerr): extend SeerrRequestService with admin methods"
```

---

## Phase 3 — View model state

### Task 7: Add admin-requests state + load methods to `CatalogViewModel`

**Files:**
- Modify: `Sodalite/Features/Catalog/CatalogViewModel.swift`

- [ ] **Step 1: Add stored properties**

In `Sodalite/Features/Catalog/CatalogViewModel.swift`, immediately after the existing `var myRequests: [SeerrRequest] = []` line, insert:

```swift
    // MARK: - Admin requests (Phase B)
    /// Loaded via `SeerrRequestService.allRequests(filter:)`. Visible
    /// only when the active SeerrUser has MANAGE_REQUESTS or ADMIN.
    var allRequests: [SeerrRequest] = []
    var allRequestsFilter: SeerrRequestFilter = .pending
    /// Per-filter total count for the chip badges. Fetched in parallel
    /// on initial load + after each successful mutation so the badges
    /// stay accurate without a full reload of the visible page.
    var allRequestsCounts: [SeerrRequestFilter: Int] = [:]
    var isLoadingAllRequests: Bool = false
    var isLoadingMoreAllRequests: Bool = false
    private var allRequestsTotal: Int = 0
    private var allRequestsSkip: Int = 0
    private let allRequestsPageSize: Int = 50
```

- [ ] **Step 2: Add load methods**

In the same file, append the following methods just before the closing `}` of the `CatalogViewModel` class (i.e. after `private func updateSection(...)`):

```swift
    // MARK: - Admin requests

    func loadAllRequests(reset: Bool) async {
        if reset {
            allRequestsSkip = 0
            allRequests = []
            allRequestsTotal = 0
        }
        guard !isLoadingAllRequests else { return }
        isLoadingAllRequests = true
        defer { isLoadingAllRequests = false }

        do {
            let result = try await requestService.allRequests(
                filter: allRequestsFilter,
                take: allRequestsPageSize,
                skip: allRequestsSkip
            )
            allRequests = result.results
            allRequestsTotal = result.pageInfo.results
            allRequestsSkip = result.results.count
            Task { await enrichRequestMetadata(for: result.results) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreAllRequests() async {
        guard allRequests.count < allRequestsTotal,
              !isLoadingMoreAllRequests,
              !isLoadingAllRequests else { return }
        isLoadingMoreAllRequests = true
        defer { isLoadingMoreAllRequests = false }

        do {
            let result = try await requestService.allRequests(
                filter: allRequestsFilter,
                take: allRequestsPageSize,
                skip: allRequestsSkip
            )
            // Dedupe against the visible list. Seerr occasionally
            // returns the same record on adjacent pages when the
            // status counts shift between fetches.
            let existing = Set(allRequests.map(\.id))
            let additions = result.results.filter { !existing.contains($0.id) }
            allRequests.append(contentsOf: additions)
            allRequestsTotal = result.pageInfo.results
            allRequestsSkip += result.results.count
            Task { await enrichRequestMetadata(for: additions) }
        } catch {
            // Mid-scroll error stays silent; the user still has the
            // visible page and can pull-to-retry by switching filters.
        }
    }

    func setAllRequestsFilter(_ filter: SeerrRequestFilter) async {
        guard allRequestsFilter != filter else { return }
        allRequestsFilter = filter
        await loadAllRequests(reset: true)
    }

    /// Fetch the `pageInfo.results` count for each filter in parallel
    /// using `take=0`. Cheap (no `results` array transferred) and
    /// drives the filter-chip badges. Failures leave the existing
    /// badge values in place — better stale than blanked out.
    func refreshAllRequestsCounts() async {
        async let pending  = try? requestService.allRequests(filter: .pending,  take: 0, skip: 0)
        async let approved = try? requestService.allRequests(filter: .approved, take: 0, skip: 0)
        async let declined = try? requestService.allRequests(filter: .declined, take: 0, skip: 0)
        async let all      = try? requestService.allRequests(filter: .all,      take: 0, skip: 0)
        let results = await (pending, approved, declined, all)
        if let p = results.0 { allRequestsCounts[.pending]  = p.pageInfo.results }
        if let a = results.1 { allRequestsCounts[.approved] = a.pageInfo.results }
        if let d = results.2 { allRequestsCounts[.declined] = d.pageInfo.results }
        if let x = results.3 { allRequestsCounts[.all]      = x.pageInfo.results }
    }
```

- [ ] **Step 3: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sodalite/Features/Catalog/CatalogViewModel.swift
git commit -m "feat(catalog): admin requests state + load/paginate/filter/counts on view model"
```

---

### Task 8: Add mutation methods (approve/decline/delete/update) to `CatalogViewModel`

**Files:**
- Modify: `Sodalite/Features/Catalog/CatalogViewModel.swift`

- [ ] **Step 1: Add an outcome enum**

In `Sodalite/Features/Catalog/CatalogViewModel.swift`, immediately after the `var isLoadingMoreAllRequests: Bool = false` line you added in Task 7, insert:

```swift
    /// Surface for the toast layer in `CatalogAllRequestsView`. Mutated
    /// by the four admin actions below; consumed via `.onChange` and
    /// cleared by the view after a short display window.
    enum AdminRequestOutcome: Equatable {
        case approved
        case declined
        case deleted
        case updated
        case failed(message: String)
        case permissionDenied
    }
    var lastAdminRequestOutcome: AdminRequestOutcome?
```

- [ ] **Step 2: Add the mutation methods**

In the same file, append after the methods you added in Task 7:

```swift
    func approveRequest(_ request: SeerrRequest) async {
        await runAdminMutation(originalRequest: request, outcome: .approved) {
            try await self.requestService.approveRequest(requestID: request.id)
        }
    }

    func declineRequest(_ request: SeerrRequest) async {
        await runAdminMutation(originalRequest: request, outcome: .declined) {
            try await self.requestService.declineRequest(requestID: request.id)
        }
    }

    func deleteRequest(_ request: SeerrRequest) async {
        // Optimistic remove; restore on failure so the user can retry.
        let snapshot = allRequests
        allRequests.removeAll { $0.id == request.id }
        do {
            try await requestService.deleteRequest(requestID: request.id)
            lastAdminRequestOutcome = .deleted
            await refreshAllRequestsCounts()
        } catch let error as APIError where error.isUnauthorized {
            allRequests = snapshot
            lastAdminRequestOutcome = .permissionDenied
        } catch {
            allRequests = snapshot
            lastAdminRequestOutcome = .failed(message: error.localizedDescription)
        }
    }

    func updateRequest(_ request: SeerrRequest, body: SeerrRequestUpdateBody) async -> SeerrRequest? {
        do {
            let updated = try await requestService.updateRequest(
                requestID: request.id,
                body: body
            )
            replaceRequest(updated)
            lastAdminRequestOutcome = .updated
            return updated
        } catch let error as APIError where error.isUnauthorized {
            lastAdminRequestOutcome = .permissionDenied
            return nil
        } catch {
            lastAdminRequestOutcome = .failed(message: error.localizedDescription)
            return nil
        }
    }

    /// Shared body for approve/decline. Optimistically replaces the
    /// row with the server's response. If the new status no longer
    /// matches the active filter, drops the row from the local list.
    /// Restores on failure so the row stays visible for retry.
    private func runAdminMutation(
        originalRequest: SeerrRequest,
        outcome: AdminRequestOutcome,
        action: @escaping () async throws -> SeerrRequest
    ) async {
        let snapshot = allRequests
        do {
            let updated = try await action()
            replaceRequest(updated)
            if !filterMatches(updated, filter: allRequestsFilter) {
                allRequests.removeAll { $0.id == updated.id }
            }
            lastAdminRequestOutcome = outcome
            await refreshAllRequestsCounts()
        } catch let error as APIError where error.isUnauthorized {
            allRequests = snapshot
            lastAdminRequestOutcome = .permissionDenied
        } catch {
            allRequests = snapshot
            lastAdminRequestOutcome = .failed(message: error.localizedDescription)
        }
    }

    private func replaceRequest(_ updated: SeerrRequest) {
        if let idx = allRequests.firstIndex(where: { $0.id == updated.id }) {
            allRequests[idx] = updated
        }
    }

    private func filterMatches(_ request: SeerrRequest, filter: SeerrRequestFilter) -> Bool {
        switch filter {
        case .all: return true
        case .pending:  return request.status == .pending
        case .approved: return request.status == .approved
        case .declined: return request.status == .declined
        }
    }
```

- [ ] **Step 3: Verify `APIError.isUnauthorized` exists**

Run: `grep -n "var isUnauthorized\|case unauthorized" Sodalite/Services/Networking/APIError.swift`
Expected: at least `case unauthorized` listed. If `isUnauthorized` computed property is missing, open `Sodalite/Services/Networking/APIError.swift` and add this extension at the bottom:

```swift
extension APIError {
    /// True for both `.unauthorized` (401) and `.httpError(403, _)`.
    /// The Seerr admin gates surface as 403; cookie expiry surfaces
    /// as 401. Both should drop the user back to a permission-denied
    /// toast.
    var isUnauthorized: Bool {
        switch self {
        case .unauthorized:                            return true
        case .httpError(let code, _) where code == 403: return true
        default:                                       return false
        }
    }
}
```

- [ ] **Step 4: Verify `SeerrRequestStatus` cases**

Run: `grep -n "case pending\|case approved\|case declined" Sodalite/Models/Seerr/SeerrRequest.swift Sodalite/Models/Seerr/*.swift`
Expected: enum cases `.pending`, `.approved`, `.declined` defined somewhere in the Seerr models. If the enum lives elsewhere or uses different names, update `filterMatches` accordingly — they must match. Likely location: a `SeerrRequestStatus` enum referenced from `SeerrRequest.status`.

- [ ] **Step 5: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sodalite/Features/Catalog/CatalogViewModel.swift Sodalite/Services/Networking/APIError.swift
git commit -m "feat(catalog): approve/decline/delete/update mutations on view model"
```

---

## Phase 4 — Catalog tab integration

### Task 9: Add allRequests Section + Picker segment to `CatalogView`

**Files:**
- Modify: `Sodalite/Features/Catalog/CatalogView.swift`

- [ ] **Step 1: Extend the Section enum**

In `Sodalite/Features/Catalog/CatalogView.swift`, replace the line:

```swift
    private enum Section: Hashable {
        case discover, myRequests
    }
```

with:

```swift
    private enum Section: Hashable {
        case discover, myRequests, allRequests
    }
```

- [ ] **Step 2: Add the third Picker segment, gated on permission**

In the same file, find the existing `Picker("", selection: $selectedSection)` block (around line 22). Replace it with:

```swift
                        Picker("", selection: $selectedSection) {
                            Text("catalog.tab.discover").tag(Section.discover)
                            Text("catalog.tab.myRequests").tag(Section.myRequests)
                            if appState.activeSeerrUser?.canManageRequests == true {
                                Text("catalog.tab.allRequests").tag(Section.allRequests)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 80)
                        .padding(.top, 20)
```

- [ ] **Step 3: Add the switch case for the new section**

In the same file, find the `switch selectedSection { case .discover: ... case .myRequests: ... }` block. Replace it with:

```swift
                        switch selectedSection {
                        case .discover:
                            CatalogDiscoverView(
                                viewModel: vm,
                                onSelect: { media in selectedMedia = media },
                                onSelectFilter: { filter in selectedFilter = filter }
                            )
                        case .myRequests:
                            CatalogMyRequestsView(viewModel: vm)
                        case .allRequests:
                            CatalogAllRequestsView(viewModel: vm)
                        }
```

- [ ] **Step 4: Trigger initial load on segment switch**

In the same file, find the `.onChange(of: selectedSection)` block and replace it with:

```swift
        .onChange(of: selectedSection) { _, newValue in
            guard let vm = viewModel else { return }
            switch newValue {
            case .myRequests:
                guard vm.myRequests.isEmpty,
                      let userID = appState.activeSeerrUser?.id else { return }
                Task { await vm.loadMyRequests(userID: userID) }
            case .allRequests:
                guard vm.allRequests.isEmpty else { return }
                Task {
                    await vm.loadAllRequests(reset: true)
                    await vm.refreshAllRequestsCounts()
                }
            case .discover:
                break
            }
        }
```

- [ ] **Step 5: Stub `CatalogAllRequestsView` so the project compiles**

Create `Sodalite/Features/Catalog/CatalogAllRequestsView.swift`:

```swift
import SwiftUI

struct CatalogAllRequestsView: View {
    @Bindable var viewModel: CatalogViewModel

    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

The view is fleshed out in Task 11; this stub keeps the build green for Phase 4.

- [ ] **Step 6: Add the localisation key for the segment label**

Open `Sodalite/Localizable.xcstrings`. Find the existing `"catalog.tab.myRequests"` entry. Add directly above or below it an entry for `"catalog.tab.allRequests"` with German as the base value:

```json
"catalog.tab.allRequests" : {
  "extractionState" : "manual",
  "localizations" : {
    "de" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Alle Anfragen"
      }
    },
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "All Requests"
      }
    }
  }
},
```

(Other 24 languages land in Task 21.)

- [ ] **Step 7: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add Sodalite/Features/Catalog/CatalogView.swift Sodalite/Features/Catalog/CatalogAllRequestsView.swift Sodalite/Localizable.xcstrings
git commit -m "feat(catalog): wire third \"Alle Anfragen\" segment gated on permissions"
```

---

## Phase 5 — Admin row + list view

### Task 10: Create `SeerrRequestAdminRow`

**Files:**
- Create: `Sodalite/Features/Catalog/SeerrRequestAdminRow.swift`

- [ ] **Step 1: Add the file**

Create `Sodalite/Features/Catalog/SeerrRequestAdminRow.swift`:

```swift
import SwiftUI

/// Admin-queue row. Differs from `SeerrRequestRow` in
/// `CatalogMyRequestsView` by (1) showing the requester's display
/// name and (2) carrying action buttons. The row itself is not
/// focusable as a single tap target — focus lands on individual
/// action buttons, mirroring the deletion-sheet pattern.
struct SeerrRequestAdminRow: View {
    let request: SeerrRequest
    let title: String?
    let year: String?
    let posterURL: URL?
    let onApprove: () -> Void
    let onEdit: () -> Void
    let onDecline: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            poster

            VStack(alignment: .leading, spacing: 8) {
                Text(resolvedTitle)
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 10) {
                    Image(systemName: typeIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(typeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let year {
                        Text("·").foregroundStyle(.tertiary)
                        Text(year).font(.caption).foregroundStyle(.secondary)
                    }
                    if request.type == .tv, let count = request.seasons?.count, count > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(count) \(seasonsLabel)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text("#\(request.id)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                if let requester = request.requestedBy {
                    Text(String(
                        format: String(
                            localized: "catalog.allRequests.requestedBy",
                            defaultValue: "Requested by %@"
                        ),
                        requester.resolvedDisplayName
                    ))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }

                SeerrEffectiveRequestBadge(request: request)

                actionRow
                    .padding(.top, 4)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.05))
        )
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            if request.status == .pending {
                AdminActionButton(
                    title: "catalog.allRequests.action.approve",
                    systemImage: "checkmark.circle.fill",
                    isProminent: true,
                    action: onApprove
                )
            }
            if request.status == .pending || request.status == .approved {
                AdminActionButton(
                    title: "catalog.allRequests.action.edit",
                    systemImage: "slider.horizontal.3",
                    action: onEdit
                )
            }
            if request.status == .pending {
                AdminActionButton(
                    title: "catalog.allRequests.action.decline",
                    systemImage: "xmark.circle",
                    action: onDecline
                )
            }
            AdminActionButton(
                title: "catalog.allRequests.action.delete",
                systemImage: "trash",
                isDestructive: true,
                action: onDelete
            )
        }
    }

    @ViewBuilder
    private var poster: some View {
        if let posterURL {
            AsyncCachedImage(url: posterURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                placeholderPoster
            }
            .frame(width: 80, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            placeholderPoster.frame(width: 80, height: 120)
        }
    }

    private var placeholderPoster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08))
            Image(systemName: typeIcon).font(.title3).foregroundStyle(.tint)
        }
    }

    private var typeIcon: String {
        switch request.type {
        case .movie: "film"
        case .tv: "tv"
        case .person: "person"
        }
    }

    private var typeLabel: String {
        switch request.type {
        case .movie: String(localized: "catalog.request.movie", defaultValue: "Movie")
        case .tv:    String(localized: "catalog.request.tv", defaultValue: "Series")
        case .person: ""
        }
    }

    private var seasonsLabel: String {
        String(localized: "catalog.allRequests.seasonsLabel", defaultValue: "Seasons")
    }

    private var resolvedTitle: String {
        if let title, !title.isEmpty { return title }
        switch request.type {
        case .movie: return String(localized: "catalog.request.placeholder.movie", defaultValue: "Movie")
        case .tv:    return String(localized: "catalog.request.placeholder.tv", defaultValue: "Series")
        case .person: return ""
        }
    }
}

/// Compact action button used in the admin row. Follows the
/// sodalite-ui-focus-and-tint rules: `.tint` ShapeStyle, focused
/// fill tinted not white, `.focusable` over material.
private struct AdminActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isProminent: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(backgroundStyle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.05 : 1.0)
        .focusable(true)
        .focused($focused)
        #if os(tvOS)
        .onLongPressGesture(minimumDuration: 0.01) { action() }
        #else
        .onTapGesture { action() }
        #endif
        .animation(.easeInOut(duration: 0.15), value: focused)
    }

    private var backgroundStyle: AnyShapeStyle {
        if isDestructive {
            return AnyShapeStyle(Color.red.opacity(focused ? 0.85 : 0.6))
        }
        if isProminent {
            return AnyShapeStyle(TintShapeStyle.tint.opacity(focused ? 0.9 : 0.55))
        }
        return AnyShapeStyle(focused
            ? TintShapeStyle.tint.opacity(0.25)
            : Color.white.opacity(0.12) as any ShapeStyle)
    }
}
```

- [ ] **Step 2: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

If it errors on `TintShapeStyle.tint.opacity(...)` formatting, simplify to:

```swift
private var backgroundStyle: AnyShapeStyle {
    if isDestructive {
        return AnyShapeStyle(Color.red.opacity(focused ? 0.85 : 0.6))
    }
    if isProminent {
        return AnyShapeStyle(.tint.opacity(focused ? 0.9 : 0.55))
    }
    return AnyShapeStyle(focused
        ? AnyShapeStyle(.tint.opacity(0.25))
        : AnyShapeStyle(Color.white.opacity(0.12)))
}
```

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Features/Catalog/SeerrRequestAdminRow.swift
git commit -m "feat(catalog): SeerrRequestAdminRow with focusable action buttons"
```

---

### Task 11: Build out `CatalogAllRequestsView`

**Files:**
- Modify: `Sodalite/Features/Catalog/CatalogAllRequestsView.swift`

- [ ] **Step 1: Replace the stub with the real view**

Replace the contents of `Sodalite/Features/Catalog/CatalogAllRequestsView.swift` with:

```swift
import SwiftUI

struct CatalogAllRequestsView: View {
    @Bindable var viewModel: CatalogViewModel
    @State private var requestPendingDecline: SeerrRequest?
    @State private var requestPendingDelete: SeerrRequest?
    @State private var requestBeingEdited: SeerrRequest?
    @State private var toastMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            filterChips
                .padding(.horizontal, 50)
                .padding(.top, 24)
                .padding(.bottom, 12)

            content
        }
        .overlay(alignment: .bottom) {
            if let msg = toastMessage {
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
        .alert(
            "catalog.allRequests.confirm.decline.title",
            isPresented: declineAlertBinding,
            presenting: requestPendingDecline
        ) { request in
            Button("common.cancel", role: .cancel) {}
            Button("catalog.allRequests.action.decline", role: .destructive) {
                Task { await viewModel.declineRequest(request) }
            }
        } message: { request in
            Text(String(
                format: String(
                    localized: "catalog.allRequests.confirm.decline.message",
                    defaultValue: "%@ will be declined. Can still be deleted later."
                ),
                viewModel.title(for: request) ?? "#\(request.id)"
            ))
        }
        .alert(
            "catalog.allRequests.confirm.delete.title",
            isPresented: deleteAlertBinding,
            presenting: requestPendingDelete
        ) { request in
            Button("common.cancel", role: .cancel) {}
            Button("catalog.allRequests.action.delete", role: .destructive) {
                Task { await viewModel.deleteRequest(request) }
            }
        } message: { request in
            Text(String(
                format: String(
                    localized: "catalog.allRequests.confirm.delete.message",
                    defaultValue: "%@ will be removed from Jellyseerr. The file stays untouched if already downloaded."
                ),
                viewModel.title(for: request) ?? "#\(request.id)"
            ))
        }
        .sheet(item: $requestBeingEdited) { request in
            SeerrRequestEditSheet(request: request, viewModel: viewModel)
        }
        .onChange(of: viewModel.lastAdminRequestOutcome) { _, outcome in
            guard let outcome else { return }
            toastMessage = toastText(for: outcome)
            viewModel.lastAdminRequestOutcome = nil
            Task {
                try? await Task.sleep(for: .seconds(3))
                if toastMessage == toastText(for: outcome) { toastMessage = nil }
            }
        }
    }

    // MARK: - Filter chips

    private var filterChips: some View {
        HStack(spacing: 12) {
            ForEach(SeerrRequestFilter.allCases) { filter in
                FilterChip(
                    title: filterTitle(filter),
                    count: viewModel.allRequestsCounts[filter],
                    isSelected: viewModel.allRequestsFilter == filter,
                    action: { Task { await viewModel.setAllRequestsFilter(filter) } }
                )
            }
            Spacer()
        }
    }

    private func filterTitle(_ filter: SeerrRequestFilter) -> LocalizedStringKey {
        switch filter {
        case .pending:  "catalog.allRequests.filter.pending"
        case .approved: "catalog.allRequests.filter.approved"
        case .declined: "catalog.allRequests.filter.declined"
        case .all:      "catalog.allRequests.filter.all"
        }
    }

    // MARK: - List body

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoadingAllRequests && viewModel.allRequests.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.allRequests.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(viewModel.allRequests.enumerated()), id: \.element.id) { index, request in
                        SeerrRequestAdminRow(
                            request: request,
                            title: viewModel.title(for: request),
                            year: viewModel.year(for: request),
                            posterURL: viewModel.posterURL(for: request),
                            onApprove: { Task { await viewModel.approveRequest(request) } },
                            onEdit:    { requestBeingEdited = request },
                            onDecline: { requestPendingDecline = request },
                            onDelete:  { requestPendingDelete = request }
                        )
                        .onAppear {
                            if index >= viewModel.allRequests.count - 5 {
                                Task { await viewModel.loadMoreAllRequests() }
                            }
                        }
                    }

                    if viewModel.isLoadingMoreAllRequests {
                        ProgressView().padding(.vertical, 20)
                    }
                }
                .padding(.horizontal, 50)
                .padding(.bottom, 40)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(emptyKey)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyKey: LocalizedStringKey {
        switch viewModel.allRequestsFilter {
        case .pending:  "catalog.allRequests.empty.pending"
        case .approved: "catalog.allRequests.empty.approved"
        case .declined: "catalog.allRequests.empty.declined"
        case .all:      "catalog.allRequests.empty.all"
        }
    }

    // MARK: - Toast text + alert bindings

    private func toastText(for outcome: CatalogViewModel.AdminRequestOutcome) -> String {
        switch outcome {
        case .approved:
            return String(localized: "catalog.allRequests.toast.approved", defaultValue: "Request approved")
        case .declined:
            return String(localized: "catalog.allRequests.toast.declined", defaultValue: "Request declined")
        case .deleted:
            return String(localized: "catalog.allRequests.toast.deleted", defaultValue: "Request deleted")
        case .updated:
            return String(localized: "catalog.allRequests.toast.updated", defaultValue: "Request updated")
        case .permissionDenied:
            return String(localized: "catalog.allRequests.toast.permissionDenied", defaultValue: "Server denied the action")
        case .failed(let message):
            return message
        }
    }

    private var declineAlertBinding: Binding<Bool> {
        Binding(
            get: { requestPendingDecline != nil },
            set: { if !$0 { requestPendingDecline = nil } }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { requestPendingDelete != nil },
            set: { if !$0 { requestPendingDelete = nil } }
        )
    }
}

// MARK: - FilterChip

private struct FilterChip: View {
    let title: LocalizedStringKey
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
            if let count {
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(isSelected
                ? AnyShapeStyle(.tint.opacity(0.65))
                : AnyShapeStyle(Color.white.opacity(0.08)))
        )
        .overlay(
            Capsule().strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.06 : 1.0)
        .focusable(true)
        .focused($focused)
        #if os(tvOS)
        .onLongPressGesture(minimumDuration: 0.01) { action() }
        #else
        .onTapGesture { action() }
        #endif
        .animation(.easeInOut(duration: 0.15), value: focused)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}
```

- [ ] **Step 2: Add stub for `SeerrRequestEditSheet` so the project compiles**

Create `Sodalite/Features/Catalog/SeerrRequestEditSheet.swift`:

```swift
import SwiftUI

struct SeerrRequestEditSheet: View {
    let request: SeerrRequest
    @Bindable var viewModel: CatalogViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            Text("Edit sheet — Task 12-16 fill this in")
                .padding()
            Button("common.cancel") { dismiss() }
        }
    }
}
```

The real implementation lands in Tasks 12-16.

- [ ] **Step 3: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sodalite/Features/Catalog/CatalogAllRequestsView.swift Sodalite/Features/Catalog/SeerrRequestEditSheet.swift
git commit -m "feat(catalog): CatalogAllRequestsView with filter chips + confirmation alerts + toast"
```

---

## Phase 6 — Edit sheet

### Task 12: Add `SeerrRequestEditSheet` state + protocol surface

**Files:**
- Modify: `Sodalite/Features/Catalog/SeerrRequestEditSheet.swift`
- Modify: `Sodalite/Services/Seerr/SeerrServiceConfigService.swift` (verify existing methods)

- [ ] **Step 1: Verify `SeerrServiceConfigService` exposes server / details fetches**

Run: `grep -n "func radarrServers\|func sonarrServers\|func radarrDetails\|func sonarrDetails" Sodalite/Services/Seerr/SeerrServiceConfigService.swift`
Expected: at least one method returning Radarr/Sonarr server lists + per-server details. If only the endpoint cases exist (Task 5 confirmed `radarrServers` / `radarrDetails` / `sonarrServers` / `sonarrDetails` are in `SeerrEndpoints.swift`), the service may need methods added. If `SeerrServiceConfigServiceProtocol` doesn't yet have:

```swift
func radarrServers() async throws -> [SeerrServer]
func radarrDetails(serverID: Int) async throws -> SeerrServiceDetails
func sonarrServers() async throws -> [SeerrServer]
func sonarrDetails(serverID: Int) async throws -> SeerrServiceDetails
```

then add them now. Use the existing `SeerrServer` model and add a `SeerrServiceDetails` model that captures the per-server detail payload: `id`, `name`, `profiles: [SeerrQualityProfile]`, `rootFolders: [SeerrRootFolder]`, and (for Sonarr) `languageProfiles: [SeerrLanguageProfile]?`. The Jellyseerr server-detail JSON shape is:

```json
{
  "server": { "id": 0, "name": "Server" },
  "profiles": [ { "id": 1, "name": "HD-1080p" } ],
  "rootFolders": [ { "id": 1, "path": "/media/movies", "freeSpace": 12345 } ],
  "languageProfiles": [ { "id": 1, "name": "English" } ]
}
```

Model files to create alongside (or top-level inside `Models/Seerr/`):

```swift
// Sodalite/Models/Seerr/SeerrServiceDetails.swift
import Foundation

struct SeerrServiceDetails: Codable, Sendable {
    let server: SeerrServer
    let profiles: [SeerrQualityProfile]
    let rootFolders: [SeerrRootFolder]
    let languageProfiles: [SeerrLanguageProfile]?
}

struct SeerrQualityProfile: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let name: String
}

struct SeerrRootFolder: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let path: String
    let freeSpace: Int64?
}

struct SeerrLanguageProfile: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let name: String
}
```

(Inspect the existing `SeerrServer.swift` first; if those structs already exist, don't duplicate. Reconcile name mismatches if needed.)

- [ ] **Step 2: Replace `SeerrRequestEditSheet` with the real skeleton**

Replace the contents of `Sodalite/Features/Catalog/SeerrRequestEditSheet.swift` with:

```swift
import SwiftUI

@MainActor
@Observable
final class SeerrRequestEditModel {
    var serverID: Int?
    var profileID: Int?
    var rootFolder: String?
    var selectedSeasons: Set<Int> = []
    var servers: [SeerrServer] = []
    var profiles: [SeerrQualityProfile] = []
    var rootFolders: [SeerrRootFolder] = []
    var isLoading: Bool = true
    var loadError: String?
    var isSaving: Bool = false

    private let request: SeerrRequest
    private let configService: SeerrServiceConfigServiceProtocol

    init(request: SeerrRequest, configService: SeerrServiceConfigServiceProtocol) {
        self.request = request
        self.configService = configService
        self.serverID = request.media?.serviceId
        if let seasons = request.seasons {
            self.selectedSeasons = Set(seasons.map(\.seasonNumber))
        }
    }

    func bootstrap() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            if request.type == .movie {
                servers = try await configService.radarrServers()
            } else {
                servers = try await configService.sonarrServers()
            }
            if let activeID = serverID ?? servers.first(where: \.isDefault)?.id ?? servers.first?.id {
                serverID = activeID
                try await loadDetails(forServerID: activeID)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func selectServer(_ id: Int) async {
        serverID = id
        profileID = nil
        rootFolder = nil
        do {
            try await loadDetails(forServerID: id)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadDetails(forServerID id: Int) async throws {
        let details: SeerrServiceDetails = request.type == .movie
            ? try await configService.radarrDetails(serverID: id)
            : try await configService.sonarrDetails(serverID: id)
        profiles = details.profiles
        rootFolders = details.rootFolders
        if profileID == nil { profileID = details.profiles.first?.id }
        if rootFolder == nil { rootFolder = details.rootFolders.first?.path }
    }

    /// Build a partial body containing only fields that differ from
    /// the original request. Avoids sending unchanged values back to
    /// Jellyseerr (defensive against server-side validation that
    /// might reject a no-op edit).
    func buildUpdateBody() -> SeerrRequestUpdateBody {
        let originalSeasons = Set((request.seasons ?? []).map(\.seasonNumber))
        let newSeasons: [Int]? = (request.type == .tv && selectedSeasons != originalSeasons)
            ? Array(selectedSeasons).sorted()
            : nil
        return SeerrRequestUpdateBody(
            serverId: serverID != request.media?.serviceId ? serverID : nil,
            profileId: profileID,
            rootFolder: rootFolder,
            languageProfileId: nil,
            seasons: newSeasons,
            userId: nil
        )
    }
}

struct SeerrRequestEditSheet: View {
    let request: SeerrRequest
    @Bindable var viewModel: CatalogViewModel
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var model: SeerrRequestEditModel?

    var body: some View {
        VStack(spacing: 24) {
            Text("Edit sheet — pickers land in Task 13-15")
            Button("common.cancel") { dismiss() }
        }
        .padding(48)
        .task {
            if model == nil {
                model = SeerrRequestEditModel(
                    request: request,
                    configService: dependencies.seerrServiceConfigService
                )
                await model?.bootstrap()
            }
        }
    }
}
```

- [ ] **Step 3: Verify `dependencies.seerrServiceConfigService` exists**

Run: `grep -n "seerrServiceConfigService" Sodalite/App/Environment/DependencyContainer.swift`
Expected: a property `let seerrServiceConfigService: SeerrServiceConfigServiceProtocol`. If missing, add it (init via existing `SeerrClient` in the same DI graph as the other Seerr services).

- [ ] **Step 4: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sodalite/Features/Catalog/SeerrRequestEditSheet.swift Sodalite/Models/Seerr/SeerrServiceDetails.swift Sodalite/Services/Seerr/SeerrServiceConfigService.swift Sodalite/App/Environment/DependencyContainer.swift
git commit -m "feat(catalog): SeerrRequestEditSheet skeleton + SeerrServiceDetails model + service plumbing"
```

---

### Task 13: Server picker in the edit sheet

**Files:**
- Modify: `Sodalite/Features/Catalog/SeerrRequestEditSheet.swift`

- [ ] **Step 1: Replace the placeholder body with the server picker**

In `Sodalite/Features/Catalog/SeerrRequestEditSheet.swift`, replace the `var body: some View` in `SeerrRequestEditSheet` (and keep everything else) with:

```swift
    var body: some View {
        if let model = model {
            sheetBody(model: model)
        } else {
            ProgressView()
                .frame(minWidth: 600, minHeight: 400)
                .task {
                    let m = SeerrRequestEditModel(
                        request: request,
                        configService: dependencies.seerrServiceConfigService
                    )
                    self.model = m
                    await m.bootstrap()
                }
        }
    }

    @ViewBuilder
    private func sheetBody(model: SeerrRequestEditModel) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("catalog.allRequests.edit.title")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(viewModel.title(for: request) ?? "#\(request.id)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = model.loadError {
                errorView(message: error, retry: { Task { await model.bootstrap() } })
            } else if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                pickerSection(model: model)
            }

            Spacer()

            footer(model: model)
        }
        .padding(48)
        .frame(maxWidth: 800)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder
    private func pickerSection(model: SeerrRequestEditModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            serverPicker(model: model)
            // profile + root folder + seasons land in Task 14-15.
        }
    }

    private func serverPicker(model: SeerrRequestEditModel) -> some View {
        EditPickerRow(
            title: request.type == .movie
                ? "catalog.allRequests.edit.server.radarr"
                : "catalog.allRequests.edit.server.sonarr",
            options: model.servers,
            selected: model.servers.first(where: { $0.id == model.serverID }),
            label: { $0.name },
            onSelect: { server in
                Task { await model.selectServer(server.id) }
            }
        )
    }

    private func footer(model: SeerrRequestEditModel) -> some View {
        HStack(spacing: 24) {
            GlassActionButton(
                title: "common.cancel",
                systemImage: "xmark",
                action: { dismiss() }
            )
            .disabled(model.isSaving)

            GlassActionButton(
                title: "catalog.allRequests.edit.save",
                systemImage: "checkmark",
                isProminent: true,
                isLoading: model.isSaving,
                action: { Task { await save(model: model) } }
            )
            .disabled(model.isSaving || model.serverID == nil)
        }
    }

    private func errorView(message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("catalog.allRequests.edit.serverLoadError")
                .font(.body)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
            Button("home.retry", action: retry)
                .buttonStyle(SettingsTileButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func save(model: SeerrRequestEditModel) async {
        model.isSaving = true
        defer { model.isSaving = false }
        let body = model.buildUpdateBody()
        let updated = await viewModel.updateRequest(request, body: body)
        if updated != nil {
            dismiss()
        }
    }
}

// MARK: - EditPickerRow

/// Generic single-select picker row for the Edit sheet. Same focus
/// conventions as ValuePickerRow: left/right cycles, `.tint` stroke,
/// `.tint`-tinted fill when focused.
private struct EditPickerRow<Option: Identifiable & Equatable>: View {
    let title: LocalizedStringKey
    let options: [Option]
    let selected: Option?
    let label: (Option) -> String
    let onSelect: (Option) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 20) {
            Text(title)
                .font(.body)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                    .font(.caption)
                    .foregroundStyle(focused ? Color.white : Color.secondary)
                    .opacity(canMoveBackward ? 1 : 0.25)
                Text(selected.map(label) ?? String(localized: "catalog.allRequests.edit.loading", defaultValue: "Loading..."))
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(minWidth: 180, alignment: .center)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(focused ? Color.white : Color.secondary)
                    .opacity(canMoveForward ? 1 : 0.25)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(focused
                      ? AnyShapeStyle(.tint.opacity(0.18))
                      : AnyShapeStyle(Color.white.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .focusable(!options.isEmpty)
        .focused($focused)
        .onMoveCommand { direction in
            switch direction {
            case .left:  advance(by: -1)
            case .right: advance(by: 1)
            default: break
            }
        }
        .animation(.easeInOut(duration: 0.15), value: focused)
    }

    private var currentIndex: Int? { options.firstIndex(where: { $0 == selected }) }
    private var canMoveBackward: Bool { (currentIndex ?? 0) > 0 }
    private var canMoveForward: Bool { (currentIndex ?? -1) < options.count - 1 }

    private func advance(by step: Int) {
        guard let idx = currentIndex else { return }
        let new = max(0, min(options.count - 1, idx + step))
        if new != idx { onSelect(options[new]) }
    }
}
```

- [ ] **Step 2: Verify `GlassActionButton` is importable**

Run: `grep -rn "struct GlassActionButton" Sodalite --include="*.swift"`
Expected: a single hit. Should already be in scope since it's used by `MediaDeletionSheet`.

- [ ] **Step 3: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sodalite/Features/Catalog/SeerrRequestEditSheet.swift
git commit -m "feat(catalog): edit sheet body + server picker + EditPickerRow"
```

---

### Task 14: Profile + Root Folder pickers

**Files:**
- Modify: `Sodalite/Features/Catalog/SeerrRequestEditSheet.swift`

- [ ] **Step 1: Add the two pickers below the server picker**

In `Sodalite/Features/Catalog/SeerrRequestEditSheet.swift`, replace the `private func pickerSection` body with:

```swift
    @ViewBuilder
    private func pickerSection(model: SeerrRequestEditModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            serverPicker(model: model)
            profilePicker(model: model)
            rootFolderPicker(model: model)
            if request.type == .tv {
                seasonsPicker(model: model)
            }
        }
    }

    private func profilePicker(model: SeerrRequestEditModel) -> some View {
        EditPickerRow(
            title: "catalog.allRequests.edit.profile",
            options: model.profiles,
            selected: model.profiles.first(where: { $0.id == model.profileID }),
            label: { $0.name },
            onSelect: { profile in model.profileID = profile.id }
        )
    }

    private func rootFolderPicker(model: SeerrRequestEditModel) -> some View {
        EditPickerRow(
            title: "catalog.allRequests.edit.rootFolder",
            options: model.rootFolders,
            selected: model.rootFolders.first(where: { $0.path == model.rootFolder }),
            label: { $0.path },
            onSelect: { folder in model.rootFolder = folder.path }
        )
    }

    @ViewBuilder
    private func seasonsPicker(model: SeerrRequestEditModel) -> some View {
        // Placeholder until Task 15 fills this in.
        EmptyView()
    }
```

- [ ] **Step 2: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Features/Catalog/SeerrRequestEditSheet.swift
git commit -m "feat(catalog): edit sheet profile + root folder pickers"
```

---

### Task 15: Seasons multi-select for TV requests

**Files:**
- Modify: `Sodalite/Features/Catalog/SeerrRequestEditSheet.swift`

- [ ] **Step 1: Implement seasons picker**

In `Sodalite/Features/Catalog/SeerrRequestEditSheet.swift`, replace the placeholder `seasonsPicker` with:

```swift
    @ViewBuilder
    private func seasonsPicker(model: SeerrRequestEditModel) -> some View {
        if let seasons = request.seasons, !seasons.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("catalog.allRequests.edit.seasons")
                    .font(.body)
                    .fontWeight(.medium)
                    .padding(.horizontal, 24)
                ForEach(seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber })) { season in
                    SeasonCheckboxRow(
                        seasonNumber: season.seasonNumber,
                        isOn: model.selectedSeasons.contains(season.seasonNumber),
                        toggle: {
                            if model.selectedSeasons.contains(season.seasonNumber) {
                                model.selectedSeasons.remove(season.seasonNumber)
                            } else {
                                model.selectedSeasons.insert(season.seasonNumber)
                            }
                        }
                    )
                }
            }
        } else {
            EmptyView()
        }
    }
}

// MARK: - SeasonCheckboxRow

/// Focusable checkbox row for one season. Follows the
/// `feedback_sodalite_ui_focus_and_tint` rules: `.focusable(true)`
/// not Button, `.tint` stroke, `.tint`-tinted fill when focused.
private struct SeasonCheckboxRow: View {
    let seasonNumber: Int
    let isOn: Bool
    let toggle: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.5)))
            Text(String(
                format: String(localized: "catalog.allRequests.edit.season.format", defaultValue: "Season %d"),
                seasonNumber
            ))
            .font(.callout)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(focused
                      ? AnyShapeStyle(.tint.opacity(0.18))
                      : AnyShapeStyle(Color.white.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .focusable(true)
        .focused($focused)
        #if os(tvOS)
        .onLongPressGesture(minimumDuration: 0.01) { toggle() }
        #else
        .onTapGesture { toggle() }
        #endif
        .animation(.easeInOut(duration: 0.15), value: focused)
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}
```

Note: the closing `}` after `seasonsPicker` closes `SeerrRequestEditSheet`. `SeasonCheckboxRow` is a sibling private struct.

- [ ] **Step 2: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Features/Catalog/SeerrRequestEditSheet.swift
git commit -m "feat(catalog): season multi-select in edit sheet"
```

---

## Phase 7 — Localisation

### Task 16: Add German base values + English for all new keys

**Files:**
- Modify: `Sodalite/Localizable.xcstrings`

- [ ] **Step 1: Add the 27 new keys**

Open `Sodalite/Localizable.xcstrings`. The file already has `"catalog.tab.allRequests"` from Task 9. Append the following 26 additional entries (German base + English; other 24 languages land in Task 17). Insert each into the alphabetical block where it belongs (Xcode is alphabetical-by-key).

Keys to add (German on left, English on right):

```
catalog.allRequests.filter.pending             "Offen"                              "Pending"
catalog.allRequests.filter.approved            "Genehmigt"                          "Approved"
catalog.allRequests.filter.declined            "Abgelehnt"                          "Declined"
catalog.allRequests.filter.all                 "Alle"                               "All"
catalog.allRequests.empty.pending              "Keine offenen Anfragen"             "No pending requests"
catalog.allRequests.empty.approved             "Keine genehmigten Anfragen"         "No approved requests"
catalog.allRequests.empty.declined             "Keine abgelehnten Anfragen"         "No declined requests"
catalog.allRequests.empty.all                  "Keine Anfragen"                     "No requests"
catalog.allRequests.action.approve             "Genehmigen"                         "Approve"
catalog.allRequests.action.edit                "Bearbeiten"                         "Edit"
catalog.allRequests.action.decline             "Ablehnen"                           "Decline"
catalog.allRequests.action.delete              "Löschen"                            "Delete"
catalog.allRequests.requestedBy                "Angefragt von %@"                   "Requested by %@"
catalog.allRequests.seasonsLabel               "Staffeln"                           "Seasons"
catalog.allRequests.confirm.decline.title      "Anfrage ablehnen?"                  "Decline request?"
catalog.allRequests.confirm.decline.message    "%@ wird abgelehnt. Kann später noch gelöscht werden."   "%@ will be declined. You can still delete it later."
catalog.allRequests.confirm.delete.title       "Anfrage löschen?"                   "Delete request?"
catalog.allRequests.confirm.delete.message     "%@ wird aus Jellyseerr entfernt. Die Datei bleibt unverändert wenn schon heruntergeladen."   "%@ will be removed from Jellyseerr. The file stays untouched if already downloaded."
catalog.allRequests.toast.approved             "Anfrage genehmigt"                  "Request approved"
catalog.allRequests.toast.declined             "Anfrage abgelehnt"                  "Request declined"
catalog.allRequests.toast.deleted              "Anfrage gelöscht"                   "Request deleted"
catalog.allRequests.toast.updated              "Anfrage aktualisiert"               "Request updated"
catalog.allRequests.toast.permissionDenied     "Server hat die Aktion abgelehnt"    "Server denied the action"
catalog.allRequests.edit.title                 "Anfrage bearbeiten"                 "Edit request"
catalog.allRequests.edit.server.radarr         "Radarr-Server"                      "Radarr server"
catalog.allRequests.edit.server.sonarr         "Sonarr-Server"                      "Sonarr server"
catalog.allRequests.edit.profile               "Quality Profile"                    "Quality profile"
catalog.allRequests.edit.rootFolder            "Root Folder"                        "Root folder"
catalog.allRequests.edit.seasons               "Staffeln"                           "Seasons"
catalog.allRequests.edit.save                  "Speichern"                          "Save"
catalog.allRequests.edit.loading               "Lädt..."                            "Loading..."
catalog.allRequests.edit.serverLoadError       "Server-Daten konnten nicht geladen werden"   "Couldn't load server data"
catalog.allRequests.edit.season.format         "Staffel %d"                         "Season %d"
```

Each entry follows Xcode's exact JSON shape, e.g.:

```json
"catalog.allRequests.filter.pending" : {
  "extractionState" : "manual",
  "localizations" : {
    "de" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Offen"
      }
    },
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Pending"
      }
    }
  }
},
```

- [ ] **Step 2: Run the xcstrings spacing sed**

Per `project_xcstrings_pipeline.md`: Xcode uses `"key" : {` (with spaces around the colon). If your editor produced `"key": {`, run:

```bash
sed -i '' 's/"\([^"]*\)": {/"\1" : {/g' Sodalite/Localizable.xcstrings
```

This is idempotent; safe to run even if no fix is needed.

- [ ] **Step 3: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sodalite/Localizable.xcstrings
git commit -m "i18n(catalog): add admin-requests keys (de + en base)"
```

---

### Task 17: Translate to the other 24 locales

**Files:**
- Modify: `Sodalite/Localizable.xcstrings`

- [ ] **Step 1: Translate each key into the 24 remaining locales**

For every key added in Task 16, add localizations for these 24 languages currently supported by the app:

```
ar, ca, cs, da, el, es, fi, fr, hu, it, ja, ko, nb, nl, pl, pt, pt-BR, ro, ru, sv, tr, uk, zh-Hans, zh-Hant
```

(Verify the exact list with: `python3 -c "import json; d=json.load(open('Sodalite/Localizable.xcstrings')); k=next(iter(d['strings'])); print(sorted(d['strings'][k]['localizations'].keys()))"` against an existing fully-translated key.)

Translation approach (matches the established workflow): generate the JSON entries with an external translator (your choice — keep wording consistent with the file-management translations from yesterday's `i18n(deletion): localise File Management UI in all 26 languages` commits), splice them into the xcstrings file inside each key's `"localizations"` object. Each translation uses the same shape:

```json
"<lang>" : {
  "stringUnit" : {
    "state" : "translated",
    "value" : "<translated value>"
  }
}
```

Preserve placeholders (`%@`, `%d`) and punctuation.

- [ ] **Step 2: Apply the spacing sed again**

```bash
sed -i '' 's/"\([^"]*\)": {/"\1" : {/g' Sodalite/Localizable.xcstrings
```

- [ ] **Step 3: Verify no diff explosion**

Run: `git diff --stat Sodalite/Localizable.xcstrings`
Expected: a meaningful number of insertions (~30 keys × 24 locales × ~6 lines = ~4300 insertions), zero deletions of unrelated lines. If you see thousands of unrelated-looking lines changed, the spacing sed missed a spot; reset and re-run.

- [ ] **Step 4: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sodalite/Localizable.xcstrings
git commit -m "i18n(catalog): translate admin-requests keys to remaining 24 locales"
```

---

## Phase 8 — Verification + ship

### Task 18: Refresh permissions on the `auth/me` restore path

**Files:**
- Modify: `Sodalite/Features/Auth/AuthService.swift` (or wherever the Seerr restore call lives — find it)

- [ ] **Step 1: Locate the Seerr restore call**

Run: `grep -rn "seerrAuthService.currentUser\|SeerrAuthService.*currentUser\|.authMe" Sodalite --include="*.swift" | head -10`

The restore path is where `SeerrAuthService.currentUser()` is called on app launch / profile restore. The decoded `SeerrUser` now includes `permissions` (Task 1), and `AppState.activeSeerrUser` is assigned from that. **No code change needed if the existing flow already assigns the full decoded user object to `AppState.activeSeerrUser`.**

- [ ] **Step 2: Confirm no manual field mapping drops `permissions`**

Look at the lines around the existing assignment. If the code does anything like:

```swift
appState.activeSeerrUser = SeerrUser(id: u.id, email: u.email, ...)  // hand-built
```

(i.e. constructs a new `SeerrUser` from individual fields rather than passing the decoded one through) update it to pass `permissions: u.permissions`. If the assignment is just `appState.activeSeerrUser = user`, no change needed.

- [ ] **Step 3: Compile and commit (only if a fix was needed in Step 2)**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5
# If a change was made:
git add Sodalite/Features/Auth/AuthService.swift  # or wherever
git commit -m "fix(auth): preserve permissions field on Seerr user restore"
```

If no change was needed, skip the commit.

---

### Task 19: Refresh permissions on 403 fallback

**Files:**
- Modify: `Sodalite/Features/Catalog/CatalogViewModel.swift`

- [ ] **Step 1: Re-fetch `auth/me` on permission denied**

In `Sodalite/Features/Catalog/CatalogViewModel.swift`, locate `runAdminMutation` and `deleteRequest` (added in Task 8). They currently set `lastAdminRequestOutcome = .permissionDenied` on `APIError.isUnauthorized`. Right after that assignment, in both methods, add:

```swift
            // Refresh the cached permissions snapshot. If the server-side
            // revoke is sticky, the next session-resume will hide the tab
            // entirely. We do not flip the local tab off here — that's
            // the AppRouter's job once it reloads activeSeerrUser.
            Task { await refreshActiveSeerrUserPermissions() }
```

Then add this private method to the class:

```swift
    private func refreshActiveSeerrUserPermissions() async {
        // The auth service lives in DI. We don't hold a reference;
        // the host can pass one or we surface a callback instead.
        // For MVP we leave this as a no-op hook for the future
        // AppRouter integration. The 403 toast is the user signal.
    }
```

Yes, this is a deliberate no-op for MVP. Wiring it to the actual `SeerrAuthService.currentUser()` requires injecting the auth service into the view model, which is a multi-call-site change. The 403 toast is sufficient user feedback; the tab will hide on next session-restore.

- [ ] **Step 2: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Features/Catalog/CatalogViewModel.swift
git commit -m "feat(catalog): refresh-permissions hook on 403 (MVP no-op, AppRouter wires later)"
```

---

### Task 20: Wire `loadAllRequests` on first appearance

**Files:**
- Modify: `Sodalite/Features/Catalog/CatalogAllRequestsView.swift`

- [ ] **Step 1: Add `.task` to load on first appearance**

In `Sodalite/Features/Catalog/CatalogAllRequestsView.swift`, add `.task` modifier to the outer `VStack` (the one wrapping `filterChips` + `content`). Insert immediately after `.animation(...)` and before `.alert(...)`:

```swift
        .task {
            if viewModel.allRequests.isEmpty {
                await viewModel.loadAllRequests(reset: true)
                await viewModel.refreshAllRequestsCounts()
            }
        }
```

This redundantly fires on the first tab switch (Task 9 already wires `.onChange(of: selectedSection)`). The duplicate is safe because both loads are guarded by `viewModel.allRequests.isEmpty`.

- [ ] **Step 2: Compile**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Features/Catalog/CatalogAllRequestsView.swift
git commit -m "feat(catalog): load admin requests on first appearance"
```

---

### Task 21: Full-feature build verification

- [ ] **Step 1: Clean build**

Run: `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' clean build 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **` with no errors or new warnings beyond the pre-existing ones noted in the project (Sendable / nonisolated(unsafe) warnings in unrelated files).

- [ ] **Step 2: Spot-check Codable round-trip in lldb / preview**

Not feasible without a running server. Manual test in Task 22 covers this.

- [ ] **Step 3: Push the branch**

```bash
git push
```

---

### Task 22: Manual test matrix on device

Each line is an action + expected outcome. Run sequentially. If a step fails, file an issue with the engine-diagnostics log (Settings → Playback → Engine Diagnostics) attached.

- [ ] **T1 — Permission gate (non-admin):** Log in as a Seerr user without `MANAGE_REQUESTS` and without `ADMIN`. Open Catalog. **Expect:** the picker shows only "Entdecken" and "Meine Anfragen". The "Alle Anfragen" segment is not visible.
- [ ] **T2 — Permission gate (admin):** Log in as a Seerr admin. Open Catalog. **Expect:** the picker shows three segments; "Alle Anfragen" is on the right.
- [ ] **T3 — Initial load:** Switch to "Alle Anfragen". **Expect:** filter "Offen" is selected, requests load, badge count matches Jellyseerr web UI.
- [ ] **T4 — Empty state:** With no pending requests on the server, switch to "Alle Anfragen". **Expect:** "Keine offenen Anfragen" empty state.
- [ ] **T5 — Filter switching:** Tap each of the four filter chips. **Expect:** list refreshes, chip badges show correct counts, empty state renders when count is 0.
- [ ] **T6 — Pagination:** With > 50 pending requests, scroll to the bottom of the list. **Expect:** spinner appears, more rows append, no duplicates.
- [ ] **T7 — Approve:** Approve a pending movie request. **Expect:** confirmation alert NOT shown (approve is non-destructive). Toast "Anfrage genehmigt" appears. Row removed from Pending filter. Chip "Offen" count decremented, "Genehmigt" incremented. Radarr now shows the title.
- [ ] **T8 — Decline:** Click Decline on a pending request. **Expect:** alert appears with title "Anfrage ablehnen?". Confirm. Toast "Anfrage abgelehnt". Row removed from Pending filter.
- [ ] **T9 — Delete:** Click Delete on any request. **Expect:** alert "Anfrage löschen?". Confirm. Toast "Anfrage gelöscht". Row removed from current view. File untouched in Jellyfin (verify in Library tab).
- [ ] **T10 — Edit (movie, change server):** Click Edit on a pending movie request. Sheet opens, server picker shows Radarr instances. Change Server. Profile + Root Folder pickers reset to new server's defaults. Tap Save. **Expect:** sheet dismisses, toast "Anfrage aktualisiert". In Jellyseerr web UI, the request now points at the new server.
- [ ] **T11 — Edit (series, change seasons):** Click Edit on a pending series request with multiple seasons. Sheet opens, all originally-requested seasons are pre-checked. Uncheck one season. Save. **Expect:** Sonarr now lists only the remaining seasons.
- [ ] **T12 — Edit error path:** Disconnect the Radarr backend in Jellyseerr (uncheck "Enabled"). Open Edit on a pending movie request. **Expect:** sheet shows "Server-Daten konnten nicht geladen werden" with a Retry button. Re-enable the backend, click Retry. **Expect:** pickers populate.
- [ ] **T13 — 403 path (server-side revoke):** While logged in as admin, revoke `MANAGE_REQUESTS` from the user in the Jellyseerr web UI. Switch back to Sodalite. Attempt to Approve a request. **Expect:** toast "Server hat die Aktion abgelehnt". Row unchanged.
- [ ] **T14 — 404 path (request gone):** Open Sodalite's Pending list. In the Jellyseerr web UI, delete one of the visible requests. In Sodalite, click Approve on the now-stale row. **Expect:** the row disappears silently or the toast surfaces the error message; no crash.
- [ ] **T15 — Localisation spot-check:** Switch tvOS device language to French (or Japanese). Reopen Catalog → Alle Anfragen. **Expect:** filter chips, action buttons, confirmations, edit-sheet labels, and toasts all render in the chosen language.
- [ ] **T16 — Profile switch:** Log out, log in as a different Seerr user (non-admin). **Expect:** "Alle Anfragen" segment disappears (CatalogView mounts fresh from the bootstrap path).
- [ ] **T17 — Focus chrome (visual):** Focus each action button on a row. **Expect:** pink-tinted stroke (the user's chosen accent), not white, not blue. Verify against the `feedback_sodalite_ui_focus_and_tint` rules.

- [ ] **Step 1: If all steps pass, tag the release**

(Optional — only if shipping standalone.)

```bash
# Find current MARKETING_VERSION in pbxproj first
grep MARKETING_VERSION Sodalite.xcodeproj/project.pbxproj | head -1
# Then create release notes + tag per existing release pattern.
```

Otherwise, the feature ships in the next aggregated version bump.

---

## Self-Review Checklist (run after writing the plan)

- [x] Every spec requirement has a task: permissions detection → T1+T2; service extensions → T5+T6; UI → T9-T15; localisation → T16+T17; manual tests → T22.
- [x] No placeholders ("TBD", "TODO", "fill in details").
- [x] Type consistency: `SeerrPermissions.manageRequests` matches across tasks; `SeerrRequestUpdateBody`'s field names match the spec body.
- [x] Each step has either concrete code or a concrete command with expected output.
- [x] Commits are scoped per task (no "fix everything" mega-commits).
- [x] Cross-references to memory rules ([[sodalite-ui-focus-and-tint]]) included where UI work happens.

---

## Open follow-ups (post-merge, not in this plan)

- Wire `refreshActiveSeerrUserPermissions` to actually call `SeerrAuthService.currentUser()` from the view model. Requires injecting the auth service or routing through `AppState` + `AppRouter`.
- Surface `MANAGE_REQUESTS` count on the Catalog tab bar icon (badge) so the admin doesn't have to enter the tab to see pending count.
- Optional: bulk approve / decline. Multi-select on row, batch action.
- Optional: 4K-toggle in edit sheet (Jellyseerr supports per-request 4K).
- If a Jellyfin user management feature lands within ~3 months, refactor the Catalog sub-tab into a top-level Admin tab and move "Alle Anfragen" + the new feature(s) under it.
