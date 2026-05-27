# Touchpad sensitivity: focus-drift mitigation

Date: 2026-05-27

## Problem

Sodalite users on the Siri Remote occasionally click the wrong tile. Pattern reported in the field: the user aims at tile A, the finger drifts a few points on the touchpad during the press, tvOS's focus engine moves focus to neighbour B in the last 20 to 60 ms before the physical click registers, and the click activates B.

Two surfaces are involved:

1. **App shell** (Home, Library, Detail, Catalog, Settings). The widely used activation pattern wires both `.onLongPressGesture(minimumDuration: 0.01)` and `.onTapGesture` onto a focusable row. Both fire on the currently focused row at click time, with no protection against last-millisecond focus shifts.
2. **Player**, in `PlayerHostController.handlePan`. Horizontal pan begins scrubbing as soon as the pan commits to the horizontal axis (40 pt travel) when the progress bar is focused or the controls are hidden. There is no velocity gate, so tiny finger drift in that state can move the timeline.

Vertical pan and horizontal button-step in the player already have a `stepMinVelocity = 400 pt/s` gate. The horizontal-scrub branch was the gap.

## Goals

- Reduce wrong-tile clicks in the app shell without changing the Sodalite focus convention (tinted halo, no Apple white halo, custom focusable rows over Apple `Button`).
- Reduce accidental scrubs in the player without making intentional scrubbing feel sluggish.
- Global, hard-wired, moderate. No new Settings UI.

## Non-goals

- No Settings toggle. Calibration values are constants in code.
- No replacement of the focusable+tap pattern with `Button`. The `feedback_sodalite_ui_focus_and_tint` rule applies.
- No new UIKit press-began bridging. The existing SwiftUI long-press timing is enough.
- No changes to discrete press handlers in the player (select, playPause, menu, arrows). These do not suffer from drift.
- No changes to the player's vertical pan, horizontal button-step, dropdown navigation, stats-overlay pan, or pan-axis commit threshold (40 pt). Those already gate on `stepMinVelocity = 400 pt/s` and behave well.

## Approach

Two independent changes, shipped together.

### Component 1: `stableTap` view modifier

A new SwiftUI `ViewModifier` that replaces the existing `onLongPressGesture(0.01) + onTapGesture` pair on focusable rows. Internally:

- Owns a `@FocusState` mirror that observes the row's focus.
- Stamps a `Date` each time focus is acquired (`focused == true`).
- Wires `onLongPressGesture(minimumDuration: 0.01)` and `onTapGesture` exactly as today.
- In the callback, fires the action only if `Date().timeIntervalSince(focusAcquiredAt) >= stableFocusWindow`. Otherwise swallows.

Constant: `stableFocusWindow = 0.08` seconds (80 ms).

Why 80 ms: human reaction time to a visual focus shift is ~200 ms. 80 ms filters drift that happens *during* the click motion itself while still letting intentional fast clicks through. If the figure turns out to feel sluggish in practice, dropping to 60 ms is a one-line tweak.

Usage replaces the existing two-line pair on each call site:

```swift
// before
.focusable(true)
.focused($focused)
.onLongPressGesture(minimumDuration: 0.01) { action() }
.onTapGesture { action() }

// after
.focusable(true)
.focused($focused)
.stableTap { action() }
```

The modifier exposes a focus binding so the caller's `@FocusState private var focused` continues to drive the row's tinted-fill styling. Two natural shapes are possible:

- **Caller-owned focus** (preferred): `func stableTap(focused: FocusState<Bool>.Binding, perform: @escaping () -> Void) -> some View`. Caller passes its existing `$focused`. Modifier reads, never writes.
- **Self-owned focus**: modifier wires its own `@FocusState`. Simpler at the call site but the caller loses the focus binding it needs for tinted styling. Rejected.

Pick caller-owned focus.

The modifier lives at `Sodalite/Components/StableTap.swift`, next to `CardButtonStyle` and the other shared focusable-card helpers.

Migration sites (verified via `grep onLongPressGesture(minimumDuration:` across the project):

- `Components/CardButtonStyle.swift`, the `FocusableCard` component, reused by `MediaCard`, `SeerrMediaCard`, `HorizontalMediaRow`, `TagRow`, and consumers in `Features/Catalog/*`, `Features/Library/FilteredGridView.swift`, `Features/Search/SearchView.swift`, `Features/Detail/SeriesDetailView.swift`. Migrating this one file alone fixes ~14 downstream surfaces.
- `Components/ExpandableTextBox.swift`
- `Features/Home/HomeCustomizeView.swift` (two sites)
- `Features/Catalog/CatalogAllRequestsView.swift`
- `Features/Catalog/SeerrRequestAdminRow.swift`
- `Features/Catalog/SeerrRequestEditSheet.swift` (two rows: toggle and option)
- `Features/Detail/MediaDeletionSheet.swift`
- `Features/Settings/PlaybackSettingsView.swift`

Total ~10 file edits, each becoming a single-line `.stableTap(focused: $focused) { action() }` (or the equivalent without an explicit body for sites where the action is a closure that always fires).

Some sites use `minimumDuration: 0`, others `0.01`. The modifier will use `0.01` internally to match the majority; the difference is not observable to users.

### Component 2: Player horizontal-scrub velocity gate

In `Sodalite/Player/PlayerHostController.swift`, the `handlePan` method, the `.horizontal` case under the non-stats, non-dropdown branch (around line 1320).

Add:

- New constant on `PlayerHostController`: `static let scrubCommitMinVelocity: CGFloat = 200` (pt/s).
- New per-gesture flag: `private var scrubCommitted: Bool = false`.
- In `.began`: reset `scrubCommitted = false` alongside the existing flag resets.
- In `.changed` with `panAxis == .horizontal && horizontalScrubs`:
  - If `!scrubCommitted` and `abs(gesture.velocity(in: view).x) < scrubCommitMinVelocity`, return without calling `viewModel.scrub(delta:)`.
  - Otherwise set `scrubCommitted = true` and proceed with the existing `viewModel.scrub(delta: t.x / width)` call.
- In `.ended`/`.cancelled`: reset `scrubCommitted = false`.

Once committed, the gesture scrubs freely for the rest of its life. The gate only prevents the *initial* unintended scrub-start from drift.

`200 pt/s` is below `stepMinVelocity = 400 pt/s` because scrubbing should still trigger on a slow, deliberate drag, not just on flicks. The Siri Remote's resting-finger drift sits roughly an order of magnitude below this (~20 to 50 pt/s).

The horizontal-into-button-step branch (`!horizontalScrubs`) already uses `stepMinVelocity = 400 pt/s` and is unchanged.

## Data flow

No new state crosses module boundaries. `stableTap` is local to each row. `scrubCommitted` is local to `PlayerHostController`. Neither writes to `UserDefaults`, `AppState`, or `DependencyContainer`.

## Error handling

No new failure modes. The modifier and the velocity gate are pure-input filters; if the timestamp or velocity reads are missing, the existing pre-change behaviour applies (fire the action / scrub).

## Testing

There is no test target in Sodalite, so verification is manual:

- **Shell:** focus tile A, drift finger to neighbour B, click. Expect: tile A activates (or nothing, if drift was timed to land between rows). Repeat with a clean fast click on B: expect B activates.
- **Player:** open a video, focus progress bar, rest finger on touchpad without intentional motion. Expect: timeline does not move. Then perform a deliberate horizontal drag, even slow. Expect: scrub responds normally.
- Regression check: vertical navigation in stats overlay and dropdown still works at the same feel.

## Open question

If the 80 ms window feels sluggish to Vincent or his girlfriend after a few days, drop to 60 ms in one line. No code structure changes needed for that.
