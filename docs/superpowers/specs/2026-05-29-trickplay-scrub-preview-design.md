# Trickplay Scrub Preview — Design

Date: 2026-05-29
Status: Approved, ready for implementation plan
Feature: Show Jellyfin trickplay thumbnail frames in the player while the user scrubs.

## Goal

While scrubbing in the player, show a thumbnail of the frame at the scrub
position, floating above the playhead, the way the native tvOS+ and Infuse
scrubbers do. Today the transport bar only shows a large time label
(`scrubTime` in `TransportBar.swift:73`); there is no image preview and no
trickplay handling anywhere in the codebase.

Sodalite is a pure client (no server transcode), so it consumes whatever
trickplay data the Jellyfin server has already generated. It does not
generate trickplay itself.

## Decisions (from brainstorming)

- **Fallback when no trickplay exists**: fall back to the current chapter's
  image if chapter images are present, otherwise the existing time-only
  preview. (Trickplay is an opt-in server scheduled task, so a meaningful
  fraction of users will not have it.)
- **Presentation**: a thumbnail card floating above the playhead, tracking
  the knob horizontally, clamped at the edges, with the time shown small
  inside the card. Native tvOS+/Infuse style.
- **Settings**: a toggle in Playback settings, default on. Off disables tile
  sheet downloads entirely.
- **Architecture**: dedicated `ScrubPreviewProvider` in the player layer plus
  a thin protocol-fronted `TrickplayService` in `Services/Jellyfin/`. The
  transport bar stays dumb (receives a ready CGImage). This mirrors the
  existing service + closure pattern (`chapterImageURL`).

## Jellyfin trickplay API (verified)

- **Manifest** ships on the item DTO: `BaseItemDto.Trickplay` is
  `{ mediaSourceId: { width: TrickplayInfo } }`. `TrickplayInfo` carries
  `Width, Height, TileWidth, TileHeight, ThumbnailCount, Interval` (ms),
  `Bandwidth`.
- **Tile sheets**: `GET /Videos/{itemId}/Trickplay/{width}/{tileIndex}.jpg?MediaSourceId={id}&api_key=…`
  returns a JPEG holding a `TileWidth x TileHeight` grid of mini frames.
- **Time to frame mapping**:
  - `thumbIndex = floor(t_ms / Interval)`
  - `perSheet = TileWidth * TileHeight`
  - `sheetIndex = thumbIndex / perSheet`
  - `pos = thumbIndex % perSheet`
  - cell at `(col = pos % TileWidth, row = pos / TileWidth)`, size `Width x Height`
  - the client downloads the sheet and crops that cell (Jellyfin serves no
    individual frames).

References: TrickplayInfoDto and BaseItemDto in the Jellyfin TypeScript SDK,
jellyfin-meta discussion #33.

## Components

### 1. Data model

- **`TrickplayInfo`**: new `Codable, Sendable` struct in `Models/Jellyfin/`,
  fields `width, height, tileWidth, tileHeight, thumbnailCount, interval,
  bandwidth`.
- **`JellyfinItem.trickplay`**: new field
  `[String: [String: TrickplayInfo]]?` with CodingKey `"Trickplay"`, outer
  key is MediaSourceId, inner key is width. Mirrors `chapters` and
  `mediaSources` (nil in the lightweight init path, copied in the
  full-item init path).
- **`JellyfinEndpoints.defaultFields`**: append `,Trickplay` so the existing
  detail fetch (which already flows into the player) returns the manifest.
  No extra request. `defaultFields` already includes `Chapters`.

### 2. Service layer — `Services/Jellyfin/TrickplayService.swift`

Protocol-fronted like the other services. Stateless, pure URL and geometry
logic:

- `resolution(for item:) -> (sourceId: String, width: Int, info: TrickplayInfo)?`
  picks the highest available width whose `Bandwidth` is under a sensible cap
  (default: the recommended mid width, not the largest, so sheets load fast
  over LAN or internet).
- `sheetURL(itemID:sourceID:width:tileIndex:) -> URL?` builds
  `/Videos/{id}/Trickplay/{width}/{tileIndex}.jpg?MediaSourceId=…&api_key=…`,
  reusing the token query-param logic from `JellyfinImageService.buildURL`
  (both `api_key` and `ApiKey` casings).
- `locate(timeSeconds:info:) -> (tileIndex: Int, cropRect: CGRect)` does the
  mapping math above.

### 3. Preview provider — `Player/ScrubPreviewProvider.swift`

`@Observable @MainActor`, owned by `PlayerViewModel`, configured in
`startPlayback` with the `item` (manifest + chapters), `TrickplayService`,
and `JellyfinImageService`. Surface:

- `private(set) var previewImage: CGImage?`
- `func update(fraction: Float, durationSeconds: Double)` debounced (~50 to
  80 ms): computes target time, resolves the sheet (cache hit crops
  immediately, miss fetches and decodes async), sets `previewImage`.
- Internal **LRU sheet cache** of decoded `CGImage` sheets (~4 to 6) plus
  **prefetch** of the neighbouring sheet so forward scrubbing does not stall.
- **Fallback chain**: no manifest, use the active chapter's image
  (`JellyfinImageService` plus the existing `chapterImageURL` logic); no
  chapter image, `previewImage = nil` and the transport bar shows time only,
  as today.
- `func reset()` clears `previewImage` and the sheet cache (called on
  teardown).

### 4. Data flow

`scrub(delta:)` in `PlayerViewModel+Scrubbing` keeps setting
`scrubProgress` / `scrubTime` and additionally calls
`scrubPreview.update(fraction:duration:)`. The provider loads and crops, then
publishes `previewImage`. `TransportBar` gains two inputs: `previewImage:
CGImage?` (and uses the existing `scrubTime`). `commitScrub`, `cancelScrub`,
and any controls-hide null out `previewImage`.

### 5. UI — `TransportBar.swift`

The existing `if isScrubbing` block (line 73) becomes a floating card: a
`ZStack` with a 16:9 frame (`Image(cgImage)`, ~320x180, rounded,
`.ultraThinMaterial` border plus shadow) and the time small underneath inside
the card. Horizontal position is driven by `scrubProgress` via the same
`knobX` math used by `progressBar`, clamped to the
`padding(.horizontal, 80)` bounds so the card never runs off screen. When
`previewImage` is nil the card falls back to today's time-only display.
Avoid image pop-in: the placeholder is the previous frame or a subtle
rectangle until the sheet arrives.

### 6. Settings

- `PlaybackPreferences.showScrubPreview: Bool`, default `true`, same `didSet`
  store pattern as the other booleans.
- A toggle row in the Playback settings view, slotted in with the other
  player toggles.
- Off: `update(...)` is a no-op, `previewImage` stays nil, time only, no
  sheet downloads.
- New Localizable keys (title and optional subtitle) shipped as real
  translations in all 26 languages, not EN-cloned stubs.

### 7. Error and edge cases

- Sheet download failure or timeout: silently fall back (chapter or time),
  no UI break, no retry storm.
- `thumbnailCount` or `interval` of 0, or a malformed manifest: treated as no
  trickplay.
- Live or transcoded sources without a stable MediaSourceId: fall back.
- Memory: the sheet cache is cleared on `stopInternal` / player teardown, so
  no heap growth across sessions (same discipline as subtitle cue retention).

### 8. Files

New: `TrickplayInfo` (in the JellyfinItem file or its own),
`TrickplayService.swift`, `ScrubPreviewProvider.swift`.

Changed: `JellyfinItem.swift`, `JellyfinEndpoints.swift`,
`PlayerViewModel.swift` (and `+Scrubbing`), `TransportBar.swift`,
`PlaybackPreferences.swift`, the Playback settings view,
`Localizable.xcstrings`, `DependencyContainer` (wire up `TrickplayService`).

### 9. Verification

There is no test target. Verification is:

- `xcodebuild -project Sodalite.xcodeproj -scheme Sodalite -destination 'generic/platform=tvOS' build`
  succeeds.
- Manual device verification on: an item with trickplay (card follows the
  knob, frame matches the position), an item without trickplay but with
  chapter images (chapter fallback), an item with neither (time only), and
  with the toggle off (time only, no downloads).
