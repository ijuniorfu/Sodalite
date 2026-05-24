# Stats for Nerds, Live Expansion

Date: 2026-05-24
Status: approved, ready for implementation plan
Tracking: Sodalite issue #8 (follow-up to the already-shipped overlay)

## Motivation

The current Stats for Nerds overlay (Sodalite be70bee, AetherEngine 36baf06) covers static metadata: codec, resolution, container bitrate, decoder identity, dynamic range, channels, language. Two gaps remain from the original issue and from real usage:

1. There is no live measurement of what is actually flowing through the pipeline. A viewer cannot tell whether a 4K HEVC HDR file is direct-playing at its full advertised bitrate or starving on the network. A developer cannot tell whether dav1d is keeping up on a dense AV1 scene.
2. Internal engine counters (AVIOReader bytes, SegmentCache total bytes, HLSLocalServer lifetime bytes sent, AudioBridge live bytes, mach RSS) already exist and are surfaced once every 30 seconds in console logs via the memprobe, but are invisible at runtime.

Goal: add a live telemetry surface to AetherEngine that powers two layers of stats in the overlay, an Enthusiast Live section visible whenever the existing toggle is on, and a deeper Engine Diagnostics block gated behind a second opt-in toggle.

## Scope

In scope:

- New `LiveTelemetry` value type on `AetherEngine`, emitted at 1 Hz while the engine is `.playing` or `.paused`.
- A new `LiveTelemetrySampler` inside the engine that produces these snapshots from existing internal counters plus a new per-path FPS counter on the software host.
- Two new sections in `StatsOverlayView`: a Live section between Playback and Video, and an Engine Diagnostics block (split into Engine, Buffer, Network sub-sections) appended below File when a new settings toggle is on.
- A new `PlaybackPreferences.showEngineDiagnostics` setting, default off, parented under the existing Stats for Nerds toggle.

Out of scope:

- Mid-stream resolution updates for software-decoded AV1 and VP9. The sequence-header tracking work was already deferred in the original issue and is unchanged here.
- Sparklines or mini-charts. Numeric readouts are sufficient.
- CSV or log export of the telemetry stream. The memprobe console line already serves the support use case.

## Architecture

Engine is the single source of truth. The host subscribes to one published value.

```
AetherEngine
├── @Published liveTelemetry: LiveTelemetry?      ← new
└── LiveTelemetrySampler                          ← new (Sources/AetherEngine/Diagnostics/)
    ├── 1 Hz Task, started on .playing, cancelled in stopInternal
    ├── reads AVIOReader.cumulativeBytesFetched
    ├── reads SegmentCache.totalBytes
    ├── reads HLSLocalServer.lifetimeBytesSent
    ├── reads AudioBridge.totalBytes (fifo + swr)
    ├── reads engine.lastAVGapMs                  (software path)
    ├── reads currentAVPlayer.currentItem.accessLog (native path)
    └── reads SoftwarePlaybackHost.framesEnqueued ← new counter

Sodalite
└── StatsOverlayView
    ├── liveSection                               ← new, always visible when stats on
    ├── playbackSection  (existing)
    ├── videoSection     (existing)
    ├── audioSection     (existing)
    ├── subtitleSection  (existing)
    ├── fileSection      (existing)
    ├── engineSection    ← new, gated by showEngineDiagnostics
    ├── bufferSection    ← new, gated by showEngineDiagnostics
    └── networkSection   ← new, gated by showEngineDiagnostics
```

The sampler runs at 1 Hz. That is fast enough that bitrate and buffer values feel current without flicker from per-GOP byte bursts, and matches what is comfortable to read on screen. The publish cost is one struct copy per second on the main actor.

## LiveTelemetry value type

```swift
public struct LiveTelemetry: Equatable, Sendable {
    // Enthusiast section
    public let instantBitrateMbps: Double?      // rolling 10s window
    public let averageBitrateMbps: Double?      // session lifetime
    public let observedFps: Double?             // software path only (live)
    public let droppedFrameCount: Int?          // native path only (cumulative)
    public let forwardBufferSeconds: Double?
    public let cachedBytes: Int64?
    public let networkThroughputMbps: Double?
    public let networkTransferredBytes: Int64?
    public let avSyncGapMs: Double?             // software path only

    // Engine diagnostics section
    public let producerRestartCount: Int
    public let muxedBytesLifetime: Int64
    public let serverBytesSentLifetime: Int64
    public let serverRequestCount: Int
    public let demuxerBytesFetched: Int64
    public let audioBridgeLiveBytes: Int
    public let rssMb: Int
}
```

Optionals encode path-asymmetry semantics. `droppedFrameCount` is nil on the software path because dav1d does not silently drop frames, it stalls (covered by the live FPS reading). `avSyncGapMs` is nil on the native path because AVPlayer owns sync internally and the engine has no comparable measurement there. `observedFps` is nil on the native path; container-declared frame rate continues to display in the static Video section.

The UI renders `—` for any nil value, never hides the row, so layout stays stable across backend switches.

## Per-path data sources

| Field | Native (AVPlayer) | Software (dav1d + sample buffer) |
|-------|-------------------|----------------------------------|
| instantBitrateMbps | AVIOReader byte delta over 10s window | same |
| averageBitrateMbps | AVIOReader cumulative / played seconds | same |
| observedFps | nil (container FPS from static section) | SoftwarePlaybackHost.framesEnqueued delta (live) |
| droppedFrameCount | AVPlayerItemAccessLogEvent.numberOfDroppedVideoFrames (cumulative) | nil |
| forwardBufferSeconds | currentItem.loadedTimeRanges, last range end minus currentTime | software host loadedTimeRanges equivalent |
| cachedBytes | SegmentCache.totalBytes | same |
| networkThroughputMbps | AccessLog observedBitrate | AVIOReader byte delta (same source as instant) |
| networkTransferredBytes | AccessLog numberOfBytesTransferred (cumulative) | AVIOReader cumulativeBytesFetched |
| avSyncGapMs | nil | engine.lastAVGapMs |

The software host gets one new counter, `framesEnqueued: Int`, incremented on every `enqueueSampleBuffer` call. Read by the sampler through the host's existing `os_unfair_lock`. Stall detection is a function of comparing this delta against the source's declared frame rate.

## Sampler design

```swift
@MainActor
final class LiveTelemetrySampler {
    private weak var engine: AetherEngine?
    private var task: Task<Void, Never>?
    private var byteWindow: RollingWindow<Int64>      // 10 buckets, 1s each
    private var frameWindow: RollingWindow<Int>       // software fps
    private var nativeAccessLogBaseline: AccessLogBaseline?

    func start()
    func stop()
}
```

Lifecycle:

| Engine event | Sampler |
|--------------|---------|
| start() reaches .playing | start sampler, allocate rolling windows |
| audio track switch (engine reloads pipeline) | stop, then start; windows are released. UI flickers nil for one tick, then resumes |
| scrub with producer restart | sampler keeps running, byte window untouched. AVIOReader bytes are monotonic across restarts, so instant bitrate dips for 1 to 2 ticks (honest signal) |
| backend switch native to software or vice versa | folds into the audio-track-switch reload path |
| stopInternal | stop sampler, release windows |
| pause | sampler continues, so buffer fluctuations remain visible |
| app to background | engine pauses, sampler is MainActor and does not tick |

Rolling windows are bounded ring buffers (10 entries). The sampler does not retain timeline data beyond 10 seconds.

## UI layout in StatsOverlayView

```
Stats for Nerds
─────────────────
LIVE                              ← new, always shown when stats on
   Bitrate        24.3 Mbps  ·  avg 22.1 Mbps
   Buffer         +18.4 s    ·  47 MB cached
   Network        45.1 Mbps  ·  1.2 GB
   Dropped Frames 0                                (native only, "—" on software)
   FPS            23.97 fps                        (software only, "—" on native)
   A/V Gap        12 ms     green                  (software only, "—" on native)

PLAYBACK   (existing)
VIDEO      (existing)
AUDIO      (existing)
SUBTITLES  (existing)
FILE       (existing)
─────────────────
ENGINE                            ← new, gated by showEngineDiagnostics
   Producer Restarts  1
   RSS                412 MB

BUFFER
   Cached Segments    9
   Demuxer Bytes      1.4 GB
   Muxed Bytes        1.3 GB
   AudioBridge        48 KB

NETWORK
   Server Sent        1.2 GB
   Server Requests    94
```

The existing arrow-key cursor in `PlayerViewModel.statsSectionAnchors` extends from 5 anchors to up to 9. When `showEngineDiagnostics` is off, Engine, Buffer, and Network anchors are filtered out before assignment, so Up/Down cycles only through the visible sections.

A/V gap is colored: green under 50 ms, yellow under 150 ms, red above. This matches the threshold used by the engine's existing A/V gap warning log (AetherEngine d4a34d4c).

## Settings

`Sodalite/Features/Settings/PlaybackPreferencesView.swift` adds a new switch as a child of the existing Stats for Nerds row.

```
Stats for Nerds                    [toggle]
Show technical playback info during playback.

   Engine Diagnostics             [toggle, disabled when parent off]
   Adds buffer, network, and subsystem counters.
   For troubleshooting.
```

`PlaybackPreferences.showEngineDiagnostics: Bool`, default false, persisted through the same `CloudSyncService` channel as `showStatsForNerds`.

## Edge cases

1. First 1 second after start, byte window is empty. `instantBitrateMbps` is nil. UI shows `—` for about one tick.
2. AVPlayer access log is empty for the first 3 to 5 seconds. `droppedFrameCount` and `networkThroughputMbps` show `—` until then. Acceptable.
3. Producer restart on scrub causes a sub-second of zero AVIOReader reads. Instant bitrate dips for 1 to 2 ticks. Intended, honest.
4. Engine is `.idle`. `liveTelemetry = nil`. Live section renders nothing. The stats overlay is only visible inside the player anyway.
5. Audio track switch reloads the pipeline. Sampler restarts, windows release. One tick of nil values.
6. Concurrency. All counters are read through existing public accessors that take their own locks (`SegmentCache.lock`, `HLSLocalServer.lock`, `AVIOReader.lock`, `AudioBridge`'s synchronized accessors). Sampler tick runs on MainActor, no new lock acquired in the engine.

## Implementation surface

New in AetherEngine:

- `Sources/AetherEngine/Diagnostics/LiveTelemetry.swift` (struct)
- `Sources/AetherEngine/Diagnostics/LiveTelemetrySampler.swift` (sampler + rolling window)
- `AetherEngine.swift`: `@Published var liveTelemetry: LiveTelemetry?`, sampler instantiation, start/stop hooks at the same points as the memprobe task (line 647, 686, 1540).
- `SoftwarePlaybackHost.swift`: new `framesEnqueued: Int` counter, incremented in `enqueueSampleBuffer`.

Modified in Sodalite:

- `Sodalite/Player/UI/StatsOverlayView.swift`: new `liveSection`, `engineSection`, `bufferSection`, `networkSection` view builders. Updated section anchor logic.
- `Sodalite/Player/PlayerViewModel.swift` (or extension): `statsSectionAnchors` becomes dynamic, filters by `showEngineDiagnostics`.
- `Sodalite/Features/Settings/PlaybackPreferencesView.swift`: new toggle UI.
- `Sodalite/Services/PlaybackPreferences.swift` (or equivalent): new `showEngineDiagnostics: Bool` property + CloudSync wiring.
- `Sodalite/Localizable.xcstrings`: new keys for Live, Engine, Buffer, Network sections and their rows. Same German plus 25 locales pattern as existing stats keys.

## Testing

No unit tests exist in this repo. Verification is manual:

1. Direct-play a 4K HEVC HDR file (native path). Confirm live bitrate is non-nil within 2 seconds and tracks a sane value. Confirm dropped frames stays at 0. Confirm A/V gap and FPS read `—`.
2. Play an AV1 file that lacks hardware decode (software path). Confirm live FPS reads near the container declared value. Confirm A/V gap renders with the right color.
3. Toggle Engine Diagnostics off and on at runtime. Confirm the three diagnostic sections appear and disappear, and the up/down cursor adjusts.
4. Scrub mid-playback. Confirm bitrate dips for 1 to 2 seconds then recovers.
5. Switch audio track mid-playback. Confirm Live section flickers nil briefly then resumes.
6. Pause for 30 seconds. Confirm cached bytes and forward buffer continue to update, instant bitrate goes to zero, average bitrate stays.

## Risk and trade-offs

- Adding a 1 Hz timer to the engine. Low risk, the memprobe task already runs from the same actor (at a much slower 30 s cadence).
- AVPlayerItemAccessLog can be expensive on some tvOS versions if read every frame. We read it once per second, well within recommended use.
- Backend switch leaves a one-tick visual artifact. Acceptable, the alternative would be cross-fading old values which is worse.

## Future work, explicitly deferred

- Mid-stream resolution change indication for software AV1 and VP9. Requires sequence-header parsing inside the software host. Separate spec when there is a real repro.
- Sparklines for bitrate or buffer. Pure UI work, no engine dependency. Defer until the numeric overlay sees enough use to justify.
