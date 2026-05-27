# Touchpad Sensitivity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mitigate Siri Remote focus drift in Sodalite. Add an 80 ms stable-focus window to focusable-row tap handling in the app shell, and a 200 pt/s velocity gate before the player begins horizontal scrubbing.

**Architecture:** Two independent changes. (1) New SwiftUI `ViewModifier` `stableTap(isFocused:perform:)` at `Sodalite/Components/StableTap.swift` that wraps the existing `onLongPressGesture(0.01)` activation with a focus-stability check, deployed to ~9 call sites across `Components/` and `Features/`. (2) New `scrubCommitMinVelocity` constant in `PlayerHostController.swift` with a `scrubCommitted` per-gesture latch that gates horizontal-pan scrubbing on the first velocity sample.

**Tech Stack:** Swift 6, SwiftUI on tvOS 26+, UIKit (`UIPanGestureRecognizer`) inside `PlayerHostController`. No new dependencies. No test target (manual verification only).

**Spec:** `docs/superpowers/specs/2026-05-27-touchpad-sensitivity-design.md` (commit `2fe0b418`).

**Build command (used in every verification step):**
```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
  -destination 'generic/platform=tvOS' build
```

**Em-dash policy:** No em-dashes or rhetorical hyphens anywhere in code, comments, commits, or this plan. Use commas, periods, or parentheses.

---

## File Structure

**New file:**
- `Sodalite/Components/StableTap.swift`: the `StableTapModifier` and `View.stableTap(isFocused:perform:)` extension.

**Modified files (app shell migration):**
- `Sodalite/Components/CardButtonStyle.swift`: `FocusableCard` (highest ROI; reused across ~14 surfaces).
- `Sodalite/Components/ExpandableTextBox.swift`: `ExpandableTextBox`.
- `Sodalite/Features/Home/HomeCustomizeView.swift`: `FocusableTile`, `FocusableIcon`.
- `Sodalite/Features/Catalog/CatalogAllRequestsView.swift`: `FilterChip`.
- `Sodalite/Features/Catalog/SeerrRequestAdminRow.swift`: `AdminActionButton`.
- `Sodalite/Features/Catalog/SeerrRequestEditSheet.swift`: `SeasonCheckboxRow`.
- `Sodalite/Features/Detail/MediaDeletionSheet.swift`: `BoolPillRow`.
- `Sodalite/Features/Settings/PlaybackSettingsView.swift`: `ValuePickerRow`.

**Modified file (player):**
- `Sodalite/Player/PlayerHostController.swift`: `handlePan` horizontal-scrub branch and the surrounding state-flag declarations.

Each task below produces one commit. Build verification happens at the end of each task, never skipped.

---

## Task 1: Create the `StableTap` modifier

**Files:**
- Create: `Sodalite/Components/StableTap.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

/// View modifier that wraps the standard Sodalite focusable-row activation
/// (clickpad press fires the action) with a focus-stability check.
///
/// On the Siri Remote, tiny finger drift in the last frames of a click can
/// shift focus from the user's intended target onto a neighbouring row,
/// so the click activates the wrong tile. This modifier records when the
/// row most recently acquired focus and only fires the action if focus
/// has been stable for at least `stableFocusWindow`. Below that threshold
/// the press is silently dropped (the user will press again on the row
/// they actually want).
///
/// 80 ms is below typical human reaction time to a visual focus shift
/// (~200 ms) so it filters drift inside a single click motion without
/// adding perceptible latency to deliberate fast clicks.
///
/// Replaces the `.onLongPressGesture(minimumDuration: 0.01) { action() }`
/// / `.onTapGesture { action() }` pair on focusable rows. The caller
/// still owns `.focusable(true)` and `.focused($focused)`, and continues
/// to drive any tint-stroke or scale-effect styling off the same
/// `@FocusState`.
struct StableTapModifier: ViewModifier {
    let isFocused: Bool
    let action: () -> Void

    /// Minimum time (s) that focus must have been steady on this row
    /// before a press is allowed to fire the action. Drop to 0.06 if
    /// 80 ms ever feels sluggish in practice.
    static let stableFocusWindow: TimeInterval = 0.08

    @State private var focusAcquiredAt: Date?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if isFocused { focusAcquiredAt = Date() }
            }
            .onChange(of: isFocused) { _, newValue in
                focusAcquiredAt = newValue ? Date() : nil
            }
            #if os(tvOS)
            .onLongPressGesture(minimumDuration: 0.01) { fireIfStable() }
            #else
            .onTapGesture { fireIfStable() }
            #endif
    }

    private func fireIfStable() {
        guard let acquired = focusAcquiredAt else { return }
        if Date().timeIntervalSince(acquired) >= Self.stableFocusWindow {
            action()
        }
    }
}

extension View {
    /// Apply a stable-focus-gated tap activation to a focusable row.
    ///
    /// Pass the same `@FocusState` value the row uses for its focus
    /// styling. The action fires only after focus has been steady on
    /// this row for `StableTapModifier.stableFocusWindow`. See the
    /// modifier docs for the rationale.
    func stableTap(isFocused: Bool, perform action: @escaping () -> Void) -> some View {
        modifier(StableTapModifier(isFocused: isFocused, action: action))
    }
}
```

- [ ] **Step 2: Verify the build**

Run:
```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
  -destination 'generic/platform=tvOS' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Components/StableTap.swift
git commit -m "$(cat <<'EOF'
feat(input): add StableTap modifier with 80 ms focus-stability window

Wraps focusable-row activation with a focus-stability check so a
last-millisecond touchpad drift onto a neighbouring row does not
fire the neighbour's action. Callers retain ownership of focusable
and focused bindings.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 2: Migrate `FocusableCard`

`FocusableCard` is the canonical media-tile activation in Sodalite, reused by `MediaCard`, `SeerrMediaCard`, `HorizontalMediaRow`, `TagRow`, and consumers in Catalog, Library, Search, Detail, and Series Detail. Migrating this one component is the highest-ROI change in the plan.

**Files:**
- Modify: `Sodalite/Components/CardButtonStyle.swift`

- [ ] **Step 1: Replace the gesture wiring**

Replace the existing `body` of `FocusableCard` (currently lines 11-21) with:

```swift
    var body: some View {
        content(isFocused)
            .focusable()
            .focused($isFocused)
            .stableTap(isFocused: isFocused) { action() }
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 20, y: 10)
            .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
```

Only the `.onLongPressGesture(minimumDuration: 0)` block changes; the surrounding modifiers stay byte-identical.

- [ ] **Step 2: Verify the build**

Run:
```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
  -destination 'generic/platform=tvOS' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Components/CardButtonStyle.swift
git commit -m "$(cat <<'EOF'
refactor(input): route FocusableCard through stableTap

FocusableCard is reused by MediaCard, SeerrMediaCard, HorizontalMediaRow,
TagRow, and most Catalog/Library/Search/Detail card surfaces, so this
single migration fixes wrong-tile clicks across ~14 surfaces.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 3: Migrate the remaining no-platform-guard sites

Three more components use the plain `.onLongPressGesture(minimumDuration: 0) { ... }` shape without a `#if os(tvOS)` guard: `ExpandableTextBox`, and `FocusableTile` plus `FocusableIcon` inside `HomeCustomizeView`. All three map to `stableTap` the same way.

**Files:**
- Modify: `Sodalite/Components/ExpandableTextBox.swift`
- Modify: `Sodalite/Features/Home/HomeCustomizeView.swift`

- [ ] **Step 1: Migrate `ExpandableTextBox`**

In `Sodalite/Components/ExpandableTextBox.swift`, replace the `.onLongPressGesture` block on the main `Text(text)` modifier chain. The current block (around lines 30-32):

```swift
            .onLongPressGesture(minimumDuration: 0) {
                showFullText = true
            }
```

becomes:

```swift
            .stableTap(isFocused: isFocused) {
                showFullText = true
            }
```

- [ ] **Step 2: Migrate `FocusableTile` in HomeCustomizeView**

In `Sodalite/Features/Home/HomeCustomizeView.swift`, inside `struct FocusableTile`, the current `body` (lines 256-265):

```swift
    var body: some View {
        content(isFocused)
            .focusable()
            .focused($isFocused)
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .onLongPressGesture(minimumDuration: 0) {
                action()
            }
    }
```

becomes:

```swift
    var body: some View {
        content(isFocused)
            .focusable()
            .focused($isFocused)
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .stableTap(isFocused: isFocused) { action() }
    }
```

- [ ] **Step 3: Migrate `FocusableIcon` in HomeCustomizeView**

In the same file, inside `struct FocusableIcon`, the current `body` (lines 277-292):

```swift
    var body: some View {
        Image(systemName: systemName)
            .font(.title2)
            .foregroundStyle(color)
            .frame(width: 60, height: 60)
            .background(
                Circle().fill(isFocused ? .white.opacity(0.15) : .clear)
            )
            .scaleEffect(isFocused ? 1.25 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .focusable()
            .focused($isFocused)
            .onLongPressGesture(minimumDuration: 0) {
                action()
            }
    }
```

becomes:

```swift
    var body: some View {
        Image(systemName: systemName)
            .font(.title2)
            .foregroundStyle(color)
            .frame(width: 60, height: 60)
            .background(
                Circle().fill(isFocused ? .white.opacity(0.15) : .clear)
            )
            .scaleEffect(isFocused ? 1.25 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .focusable()
            .focused($isFocused)
            .stableTap(isFocused: isFocused) { action() }
    }
```

- [ ] **Step 4: Verify the build**

Run:
```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
  -destination 'generic/platform=tvOS' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sodalite/Components/ExpandableTextBox.swift Sodalite/Features/Home/HomeCustomizeView.swift
git commit -m "$(cat <<'EOF'
refactor(input): route ExpandableTextBox and HomeCustomize tiles through stableTap

ExpandableTextBox, FocusableTile, and FocusableIcon all used the same
plain onLongPressGesture activation. Migrated to stableTap so the focus
drift filter applies on the Home customization screen and on detail
overview text boxes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 4: Migrate `#if os(tvOS)` guarded sites

Five rows use the platform-guarded shape `#if os(tvOS) .onLongPressGesture(minimumDuration: 0.01) { action } #else .onTapGesture { action } #endif`. The modifier already handles both branches internally, so the migration replaces the entire `#if ... #endif` block with one `.stableTap(...)` call.

**Files:**
- Modify: `Sodalite/Features/Catalog/CatalogAllRequestsView.swift`
- Modify: `Sodalite/Features/Catalog/SeerrRequestAdminRow.swift`
- Modify: `Sodalite/Features/Catalog/SeerrRequestEditSheet.swift`
- Modify: `Sodalite/Features/Detail/MediaDeletionSheet.swift`
- Modify: `Sodalite/Features/Settings/PlaybackSettingsView.swift`

- [ ] **Step 1: Migrate `FilterChip` in CatalogAllRequestsView**

The relevant block (around lines 241-245) currently:

```swift
        #if os(tvOS)
        .onLongPressGesture(minimumDuration: 0.01) { action() }
        #else
        .onTapGesture { action() }
        #endif
```

becomes:

```swift
        .stableTap(isFocused: focused) { action() }
```

- [ ] **Step 2: Migrate `AdminActionButton` in SeerrRequestAdminRow**

The relevant block (around lines 198-202) currently:

```swift
        #if os(tvOS)
        .onLongPressGesture(minimumDuration: 0.01) { action() }
        #else
        .onTapGesture { action() }
        #endif
```

becomes:

```swift
        .stableTap(isFocused: focused) { action() }
```

- [ ] **Step 3: Migrate `SeasonCheckboxRow` in SeerrRequestEditSheet**

The relevant block (around lines 329-333) currently:

```swift
        #if os(tvOS)
        .onLongPressGesture(minimumDuration: 0.01) { toggle() }
        #else
        .onTapGesture { toggle() }
        #endif
```

becomes:

```swift
        .stableTap(isFocused: focused) { toggle() }
```

- [ ] **Step 4: Migrate `BoolPillRow` in MediaDeletionSheet**

The relevant block (around lines 331-343) currently:

```swift
        #if os(tvOS)
        // Siri Remote click toggles the binding. minimumDuration: 0.01
        // matches ValuePickerRow's pattern (a near-zero long-press
        // gesture is how tvOS Swift surfaces the clickpad press to a
        // non-Button focusable view).
        .onLongPressGesture(minimumDuration: 0.01) {
            if !disabled { isOn.toggle() }
        }
        #else
        .onTapGesture {
            if !disabled { isOn.toggle() }
        }
        #endif
```

becomes:

```swift
        .stableTap(isFocused: focused) {
            if !disabled { isOn.toggle() }
        }
```

The leading explanatory comment block is removed: `stableTap`'s own docs cover the rationale.

- [ ] **Step 5: Migrate `ValuePickerRow` in PlaybackSettingsView**

The relevant block (around lines 473-479) currently:

```swift
        // Pressing the clickpad also advances forward for users who
        // prefer clicking over swiping.
        #if os(tvOS)
        .onLongPressGesture(minimumDuration: 0.01) {
            advance(by: 1)
        }
        #endif
```

becomes:

```swift
        // Pressing the clickpad also advances forward for users who
        // prefer clicking over swiping.
        .stableTap(isFocused: focused) {
            advance(by: 1)
        }
```

The behavioural comment stays (it describes intent, not platform plumbing).

- [ ] **Step 6: Verify the build**

Run:
```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
  -destination 'generic/platform=tvOS' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Sodalite/Features/Catalog/CatalogAllRequestsView.swift \
        Sodalite/Features/Catalog/SeerrRequestAdminRow.swift \
        Sodalite/Features/Catalog/SeerrRequestEditSheet.swift \
        Sodalite/Features/Detail/MediaDeletionSheet.swift \
        Sodalite/Features/Settings/PlaybackSettingsView.swift
git commit -m "$(cat <<'EOF'
refactor(input): route platform-guarded tap rows through stableTap

Migrate FilterChip, AdminActionButton, SeasonCheckboxRow, BoolPillRow,
and ValuePickerRow off the bespoke #if os(tvOS) / #else gesture pair
onto the shared stableTap modifier, picking up the 80 ms focus-stability
window on Settings, Catalog, Edit, and Delete sheets.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 5: Player horizontal-scrub velocity gate

Mirror the existing step-fire pattern: introduce a per-gesture `scrubCommitted` latch and a `scrubCommitMinVelocity` constant, and require the velocity threshold to be crossed once before the horizontal pan begins moving the timeline. Slow but deliberate scrubs still go through; resting-finger drift (typically below 50 pt/s) does not.

**Files:**
- Modify: `Sodalite/Player/PlayerHostController.swift`

- [ ] **Step 1: Add the constant and the per-gesture flag**

Locate the existing constants block (currently around line 1209, just above `handlePan`):

```swift
    private static let panAxisCommitThreshold: CGFloat = 40
    /// Travel (pt) on the committed vertical axis before we fire an
    /// up/down, one fire per gesture, matching the single-shot feel
    /// of pressing the arrow keys.
    private static let verticalFireThreshold: CGFloat = 150
    /// Travel (pt) on a horizontal swipe before we fire left/right when
    /// the swipe is being used for transport-button navigation rather
    /// than scrubbing, same single-shot behaviour as vertical.
    private static let horizontalFireThreshold: CGFloat = 150
    /// Minimum velocity (pt/s) for a step-firing pan to count as an
    /// intentional swipe. The Siri Remote's touchpad reports tiny
    /// finger drift while the user is just resting their finger before
    /// a click, over a second or two that drift can accumulate past
    /// the distance threshold above and steal focus to the wrong
    /// button. Requiring velocity as well filters out the slow drift
    /// case while still letting any real swipe through (typical
    /// directional swipes are well above 1000 pt/s).
    private static let stepMinVelocity: CGFloat = 400
```

Add a new constant immediately after `stepMinVelocity`:

```swift
    /// Minimum velocity (pt/s) for a horizontal pan to commit to
    /// scrubbing the timeline. Lower than stepMinVelocity because
    /// scrubbing should still trigger on a slow but deliberate drag,
    /// while the Siri Remote's resting-finger drift (roughly an order
    /// of magnitude below this) should not nudge the timeline. The
    /// gate only applies to the initial commit per gesture; once
    /// scrubbing has started the pan runs at full sensitivity.
    private static let scrubCommitMinVelocity: CGFloat = 200
```

Then locate the per-gesture flags (currently around line 1184):

```swift
    private var panAxis: PanAxis = .undetermined
    private var verticalStepFired = false
    private var horizontalStepFired = false
```

Add a new flag below:

```swift
    private var scrubCommitted = false
```

- [ ] **Step 2: Wire the latch into `handlePan`**

There are three places in `handlePan` (around lines 1226-1356) that reset the per-gesture flags. Each needs `scrubCommitted = false` added.

**(a) Stats-overlay branch, `.began` case:** currently:

```swift
            case .began:
                panAxis = .undetermined
                verticalStepFired = false
```

becomes:

```swift
            case .began:
                panAxis = .undetermined
                verticalStepFired = false
                scrubCommitted = false
```

**(b) Stats-overlay branch, `.ended`/`.cancelled` case:** currently:

```swift
            case .ended, .cancelled:
                panAxis = .undetermined
                verticalStepFired = false
```

becomes:

```swift
            case .ended, .cancelled:
                panAxis = .undetermined
                verticalStepFired = false
                scrubCommitted = false
```

**(c) Main branch, `.began` case:** currently:

```swift
        case .began:
            panAxis = .undetermined
            verticalStepFired = false
            horizontalStepFired = false
```

becomes:

```swift
        case .began:
            panAxis = .undetermined
            verticalStepFired = false
            horizontalStepFired = false
            scrubCommitted = false
```

**(d) Main branch, `.ended`/`.cancelled` case:** currently:

```swift
        case .ended, .cancelled:
            // Only finalise a scrub when the pan was actually scrubbing,
            // horizontal-into-navigation doesn't touch the timeline, so
            // no scrubPanEnded() to commit or cancel.
            if panAxis == .horizontal && horizontalScrubs {
                viewModel.scrubPanEnded()
            }
            panAxis = .undetermined
            verticalStepFired = false
            horizontalStepFired = false
```

becomes:

```swift
        case .ended, .cancelled:
            // Only finalise a scrub when the pan was actually scrubbing,
            // horizontal-into-navigation doesn't touch the timeline, so
            // no scrubPanEnded() to commit or cancel.
            if panAxis == .horizontal && horizontalScrubs {
                viewModel.scrubPanEnded()
            }
            panAxis = .undetermined
            verticalStepFired = false
            horizontalStepFired = false
            scrubCommitted = false
```

- [ ] **Step 3: Gate the horizontal-scrub branch on velocity**

Locate the horizontal-scrub branch inside the main `.changed` handler (currently around lines 1319-1322):

```swift
            switch panAxis {
            case .horizontal:
                if horizontalScrubs {
                    let width = max(view.bounds.width, 1)
                    viewModel.scrub(delta: t.x / width)
                } else {
```

Replace with:

```swift
            switch panAxis {
            case .horizontal:
                if horizontalScrubs {
                    if !scrubCommitted {
                        let v = gesture.velocity(in: view)
                        guard abs(v.x) >= Self.scrubCommitMinVelocity else { return }
                        scrubCommitted = true
                    }
                    let width = max(view.bounds.width, 1)
                    viewModel.scrub(delta: t.x / width)
                } else {
```

The `else` branch (horizontal-into-button-step) is unchanged. The vertical and undetermined cases are unchanged.

- [ ] **Step 4: Verify the build**

Run:
```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
  -destination 'generic/platform=tvOS' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sodalite/Player/PlayerHostController.swift
git commit -m "$(cat <<'EOF'
feat(player): gate horizontal scrub on 200 pt/s velocity

Add scrubCommitMinVelocity and a per-gesture scrubCommitted latch so
the player's horizontal pan does not begin moving the timeline until
the first velocity sample crosses 200 pt/s. Filters Siri Remote
resting-finger drift without affecting deliberate slow scrubs.
Mirrors the existing step-fire pattern used for vertical and
horizontal button navigation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 6: Manual smoke test

There is no test target. Verify on real hardware (Apple TV 4K with Siri Remote) before declaring the feature done. If hardware is not available, the tvOS simulator with Hardware → Show Apple TV Remote works for the app-shell checks; player checks need physical hardware because the simulator does not produce drift samples.

- [ ] **Step 1: Run the app on hardware**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
  -destination 'generic/platform=tvOS' build
```

Then run from Xcode against an Apple TV destination, or sideload via TestFlight.

- [ ] **Step 2: Verify app-shell stable-focus gate**

For each surface below, focus a tile, rest the finger and let it drift onto a neighbour, then click. Expected: the originally focused tile activates, or no activation if drift was timed exactly during the press. Repeat with a clean fast click on the neighbour: it should activate normally.

Surfaces to check:
- Home media-row tile (covers `MediaCard` via `FocusableCard`)
- Library grid item (covers `MediaCard` via `FocusableCard`)
- Search result item
- Catalog (Seerr) media tile
- Catalog admin-row action button (Approve, Decline)
- Catalog filter chip (FilterChip)
- Catalog Edit-sheet season checkbox
- Detail-view Overview text box (ExpandableTextBox)
- Settings → Playback value-picker row (clickpad-advance)
- Delete sheet pill rows (BoolPillRow)
- Home → Customize tile and plus/minus icon

- [ ] **Step 3: Verify player horizontal-scrub gate**

Open a video. Verify each:
- Focus the progress bar, rest finger on touchpad with no intentional motion. Expected: timeline does not move.
- Focus the progress bar, perform a deliberate slow horizontal drag (well above 200 pt/s, well below the previous behaviour's effective rate). Expected: scrub responds smoothly.
- Hide controls (wait for auto-hide), then swipe horizontally with intent. Expected: scrub still works.
- Focus a transport button (Skip Intro, Audio, Subtitles, Speed). Swipe horizontally between buttons. Expected: single-step navigation still feels the same (the `stepMinVelocity = 400 pt/s` gate already covered this).

- [ ] **Step 4: Regression check the unrelated pan paths**

- Open the stats overlay (3-finger swipe or however your build wires it). Vertical swipe should still page the overlay's section cursor; horizontal swipe should still be swallowed.
- Open a dropdown in the player (audio, subtitle, speed). Vertical swipe should still step through items with the existing 120 pt-per-step feel.

- [ ] **Step 5: If everything passes, the feature is shipped**

No additional commit needed. All work is already on `main`. If something feels off, capture which surface and which input gesture, then iterate before claiming the work done.

---

## Self-review checklist (already applied while writing)

- Spec coverage: Task 1 covers the modifier itself. Tasks 2 to 4 cover all ~9 file edits from the spec's migration list (CardButtonStyle, ExpandableTextBox, HomeCustomizeView, CatalogAllRequestsView, SeerrRequestAdminRow, SeerrRequestEditSheet, MediaDeletionSheet, PlaybackSettingsView). Task 5 covers the player velocity gate. Task 6 covers manual verification.
- Placeholder scan: no TBDs, no "implement later", every step contains the exact replacement code.
- Type consistency: the modifier is called `stableTap(isFocused:perform:)` everywhere in the plan; the constant is `stableFocusWindow`; the player adds `scrubCommitMinVelocity` and `scrubCommitted`, matching the spec.
- Em-dashes: none in the plan, none in any commit message, none in the new source comments.
