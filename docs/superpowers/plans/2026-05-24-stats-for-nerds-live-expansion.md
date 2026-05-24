# Stats for Nerds Live Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface a 1 Hz live-telemetry stream from AetherEngine into Sodalite's Stats for Nerds overlay, with an opt-in Engine Diagnostics deeper layer.

**Architecture:** New `LiveTelemetry` struct + `LiveTelemetrySampler` in AetherEngine emit at 1 Hz, pulling from existing counters (AVIOReader, SegmentCache, HLSLocalServer, AudioBridge), one new counter (`SoftwarePlaybackHost.framesEnqueued`), AVPlayerItemAccessLog (native), and two new published signals (producer restart count, last A/V gap ms). Sodalite extends `StatsOverlayView` with a Live section (always shown when stats on) and three diagnostic sections (Engine, Buffer, Network) gated by a new preference toggle.

**Tech Stack:** Swift 6, SwiftUI, Combine, AVFoundation, AetherEngine package.

**Repos involved:**
- AetherEngine: `~/Dev/AetherEngine` — engine instrumentation (Phase 1)
- Sodalite: `~/Dev/Sodalite` — host UI + settings + engine pin bump (Phase 2)

**Verification model:** No unit-test target exists. Each task verifies via `xcodebuild` for compile and via a documented manual playback check at the end of each phase.

**Spec:** `docs/superpowers/specs/2026-05-24-stats-for-nerds-live-expansion-design.md`

---

## Phase 1 — AetherEngine instrumentation

Working dir for all Phase 1 tasks: `/Users/vincentherbst/Dev/AetherEngine`

### Task 1: Add `LiveTelemetry` value type

**Files:**
- Create: `Sources/AetherEngine/Diagnostics/LiveTelemetry.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Snapshot of live playback telemetry, emitted by `LiveTelemetrySampler`
/// at 1 Hz while the engine is `.playing` or `.paused`. Optionals encode
/// path-asymmetry: a `nil` value means the field is not available on the
/// current backend (e.g. `droppedFrameCount` is `nil` on the software
/// path because dav1d does not silently drop frames, and `avSyncGapMs`
/// is `nil` on the native path because AVPlayer owns sync internally).
public struct LiveTelemetry: Equatable, Sendable {
    // Enthusiast section
    public let instantBitrateMbps: Double?
    public let averageBitrateMbps: Double?
    public let observedFps: Double?
    public let droppedFrameCount: Int?
    public let forwardBufferSeconds: Double?
    public let cachedBytes: Int64?
    public let networkThroughputMbps: Double?
    public let networkTransferredBytes: Int64?
    public let avSyncGapMs: Double?

    // Engine diagnostics section
    public let producerRestartCount: Int
    public let muxedBytesLifetime: Int64
    public let serverBytesSentLifetime: Int64
    public let serverRequestCount: Int
    public let demuxerBytesFetched: Int64
    public let audioBridgeLiveBytes: Int
    public let rssMb: Int

    public init(
        instantBitrateMbps: Double?,
        averageBitrateMbps: Double?,
        observedFps: Double?,
        droppedFrameCount: Int?,
        forwardBufferSeconds: Double?,
        cachedBytes: Int64?,
        networkThroughputMbps: Double?,
        networkTransferredBytes: Int64?,
        avSyncGapMs: Double?,
        producerRestartCount: Int,
        muxedBytesLifetime: Int64,
        serverBytesSentLifetime: Int64,
        serverRequestCount: Int,
        demuxerBytesFetched: Int64,
        audioBridgeLiveBytes: Int,
        rssMb: Int
    ) {
        self.instantBitrateMbps = instantBitrateMbps
        self.averageBitrateMbps = averageBitrateMbps
        self.observedFps = observedFps
        self.droppedFrameCount = droppedFrameCount
        self.forwardBufferSeconds = forwardBufferSeconds
        self.cachedBytes = cachedBytes
        self.networkThroughputMbps = networkThroughputMbps
        self.networkTransferredBytes = networkTransferredBytes
        self.avSyncGapMs = avSyncGapMs
        self.producerRestartCount = producerRestartCount
        self.muxedBytesLifetime = muxedBytesLifetime
        self.serverBytesSentLifetime = serverBytesSentLifetime
        self.serverRequestCount = serverRequestCount
        self.demuxerBytesFetched = demuxerBytesFetched
        self.audioBridgeLiveBytes = audioBridgeLiveBytes
        self.rssMb = rssMb
    }
}
```

- [ ] **Step 2: Verify compile**

Run: `cd ~/Dev/AetherEngine && swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/AetherEngine
git add Sources/AetherEngine/Diagnostics/LiveTelemetry.swift
git commit -m "$(cat <<'EOF'
feat(diagnostics): add LiveTelemetry value type

Snapshot struct emitted at 1 Hz by an upcoming sampler. Optionals
encode per-backend asymmetry (e.g. droppedFrameCount nil on software,
avSyncGapMs nil on native).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Expose live counters that the engine already tracks privately

**Files:**
- Modify: `Sources/AetherEngine/Video/HLSSegmentProducer.swift` (add restart counter + last AV gap fields, wire from existing gap log)
- Modify: `Sources/AetherEngine/Video/HLSVideoEngine.swift` (forward producer restart count + last AV gap to the engine-side aggregator)
- Modify: `Sources/AetherEngine/Network/HLSLocalServer.swift` (expose request count)

- [ ] **Step 1: Add restart counter + last AV gap fields to HLSSegmentProducer**

Open `Sources/AetherEngine/Video/HLSSegmentProducer.swift`. Find the existing gap-log site near line 1093 — the block that computes `let gapMs = ...` and logs when `abs(gapMs) > 50`.

Add these instance properties near the other producer state (e.g. just below `restartTargetVideoDts` around line 259):

```swift
    /// Counter for forward-only producer restarts triggered by
    /// HLSVideoEngine. Surfaced via the engine's live telemetry so the
    /// stats overlay can show how aggressively AVPlayer is re-priming
    /// segment requests after scrubs. Reset to 0 on every new session
    /// (each producer instance is per-session).
    private(set) var restartCount: Int = 0

    /// Most recently measured open-audio-gate vs. open-video-gate gap,
    /// in source-clock milliseconds. Already computed inline for the
    /// existing log line at the gap-detection site; stored here so the
    /// engine memprobe and the live telemetry sampler can read it
    /// without re-deriving it.
    private(set) var lastAVGapMs: Double = 0
```

In the constructor or the gate-open path that already runs the existing gap calculation (around line 1093 — the `let gapMs = audioTb.den > 0 ...` block), add right after `let gapMs = ...`:

```swift
                        self.lastAVGapMs = gapMs
```

Find the point where the producer is told to restart by HLSVideoEngine. Grep for `restartTargetVideoDts` to locate where the producer enters a restart phase (look at `init`-time when `restartTargetVideoDts > 0`). Increment `restartCount` once at the top of the pump loop for restart sessions only. Specifically, add inside `runPumpLoop` (find it via `grep -n "runPumpLoop" Sources/AetherEngine/Video/HLSSegmentProducer.swift`) right after the first log line of the function:

```swift
        if restartTargetVideoDts > 0 {
            restartCount &+= 1
        }
```

This counts each restart instance once. (Phase A producers — non-restart — leave it at 0.)

- [ ] **Step 2: Expose request count on HLSLocalServer**

Open `Sources/AetherEngine/Network/HLSLocalServer.swift`. Find `_lifetimeBytesSent` near line 258. Add alongside it:

```swift
    private var _requestCount: Int = 0
    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requestCount
    }
```

Find every place a new connection's request line is parsed and served. The cleanest hook is the handler function that already exists. Grep for the spot that increments `_lifetimeBytesSent &+=` to find the served-response path. Just before that increment (or at the start of the response handler — whichever is the single per-request entry point), add inside the existing `lock.lock()` block:

```swift
        _requestCount &+= 1
```

If `_lifetimeBytesSent` is incremented multiple times per request (once per chunk), instead increment `_requestCount` in the connection-accept path. Verify by reading lines 250 - 280 of the file.

- [ ] **Step 3: Forward restart count + last AV gap to HLSVideoEngine memprobe surface**

Open `Sources/AetherEngine/Video/HLSVideoEngine.swift` and find the memprobe-export function around line 1131 (`segmentCacheBytes: cache?.totalBytes ?? 0,`). Read the surrounding `MemprobeSnapshot`/return type to confirm shape, then add to the same call:

```swift
            producerRestartCount: producer?.restartCount ?? 0,
            lastAVGapMs: producer?.lastAVGapMs ?? 0,
            serverRequestCount: server?.requestCount ?? 0,
```

If the snapshot struct doesn't yet contain those fields, also add them to the struct definition (read the file to find it, likely near the top of HLSVideoEngine). Make all three `let`s with the right types (`Int`, `Double`, `Int`). Initialize matching defaults wherever the snapshot is constructed.

- [ ] **Step 4: Compile-verify**

Run: `cd ~/Dev/AetherEngine && swift build`
Expected: succeeds. If the memprobe struct has named members the new ones break the initialiser, fix call-sites the compiler reports.

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/AetherEngine
git add Sources/AetherEngine/Video/HLSSegmentProducer.swift \
        Sources/AetherEngine/Video/HLSVideoEngine.swift \
        Sources/AetherEngine/Network/HLSLocalServer.swift
git commit -m "$(cat <<'EOF'
feat(diagnostics): expose producer restart count, last AV gap, server request count

Stores existing inline gap measurement in lastAVGapMs, increments
restartCount once per restart-session pump-loop entry, and counts
HTTP requests served by the loopback server. All three feed the
upcoming LiveTelemetry surface.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add framesEnqueued counter to SoftwarePlaybackHost

**Files:**
- Modify: `Sources/AetherEngine/Native/SoftwarePlaybackHost.swift`

- [ ] **Step 1: Locate the renderer enqueue point**

Open `Sources/AetherEngine/Native/SoftwarePlaybackHost.swift`. Find the line `self?.renderer.enqueue(pixelBuffer: pixelBuffer, pts: pts, hdr10PlusData: hdr10PlusData)` around line 199. That is the single point where a decoded video frame is handed off to the sample-buffer display layer.

Confirm there is an existing serial queue or lock guarding the surrounding closure. (Read lines 30 - 80 of the file to find any existing `os_unfair_lock` or actor-isolation.)

- [ ] **Step 2: Add the counter**

Near the top of the class (just below `final class SoftwarePlaybackHost {` at line 34), add:

```swift
    /// Frames successfully enqueued into the AVSampleBufferDisplayLayer.
    /// Incremented each time `renderer.enqueue` is invoked. Read by the
    /// engine's LiveTelemetrySampler at 1 Hz to compute observed FPS on
    /// the software path. Atomic read via the existing class-internal
    /// serialisation; the counter is single-writer (the decode pump) and
    /// any reader sees a torn `Int` only on 32-bit platforms (tvOS is
    /// 64-bit, so reads are atomic by ABI).
    private(set) var framesEnqueued: Int = 0
```

At the enqueue call site (the `self?.renderer.enqueue(...)` line), add immediately after it:

```swift
                self?.framesEnqueued &+= 1
```

Also add for the audio-renderer call at line 492 (`aOut.enqueue(sampleBuffer: buf)`) — actually, audio framerate isn't useful for FPS measurement. **Do not** add a counter at the audio enqueue site. Only video.

- [ ] **Step 3: Compile**

Run: `cd ~/Dev/AetherEngine && swift build`
Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
cd ~/Dev/AetherEngine
git add Sources/AetherEngine/Native/SoftwarePlaybackHost.swift
git commit -m "$(cat <<'EOF'
feat(diagnostics): add framesEnqueued counter to SoftwarePlaybackHost

Single-writer Int incremented at each renderer.enqueue call site. Read
at 1 Hz by the upcoming LiveTelemetrySampler to compute live FPS on
the software path (dav1d/AV1) where a stall manifests as a falling
enqueue rate rather than as dropped frames.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Expose residentMemoryMB as an internal helper

**Files:**
- Modify: `Sources/AetherEngine/AetherEngine.swift`

The existing helper at line 1690 is `private static`. The sampler needs to call it.

- [ ] **Step 1: Change visibility**

Find around line 1690:

```swift
    private static func residentMemoryMB() -> Int {
```

Change to:

```swift
    static func residentMemoryMB() -> Int {
```

(Drop `private`. `internal` is the default within the package, which is what we want — public would expose it to host apps unnecessarily.)

- [ ] **Step 2: Compile + commit**

```bash
cd ~/Dev/AetherEngine
swift build
git add Sources/AetherEngine/AetherEngine.swift
git commit -m "$(cat <<'EOF'
refactor(diagnostics): make residentMemoryMB internal

Was private static. Needed by the upcoming LiveTelemetrySampler in
the same module.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Implement `LiveTelemetrySampler`

**Files:**
- Create: `Sources/AetherEngine/Diagnostics/LiveTelemetrySampler.swift`

- [ ] **Step 1: Write the rolling-window helper**

This file holds the sampler + a small ring buffer used for the 10-second bitrate window.

```swift
import Foundation
import AVFoundation

/// Bounded ring buffer that retains the most recent `capacity` values
/// and exposes their sum. Used for 10-second rolling windows of byte
/// counts (for instant-bitrate) and frame counts (for observed FPS).
struct RollingWindow<T: AdditiveArithmetic> {
    private var buffer: [T]
    private var index: Int = 0
    private var filled: Bool = false
    let capacity: Int

    init(capacity: Int, zero: T) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.buffer = Array(repeating: zero, count: capacity)
    }

    mutating func push(_ value: T) {
        buffer[index] = value
        index = (index + 1) % capacity
        if index == 0 { filled = true }
    }

    var sum: T {
        let active = filled ? buffer : Array(buffer.prefix(index))
        return active.reduce(.zero, +)
    }

    /// Number of slots actually populated (less than `capacity` until
    /// the buffer wraps for the first time). Used by the sampler to
    /// keep instant-bitrate `nil` until the window has at least 2
    /// samples — one sample is a delta of zero seconds.
    var count: Int { filled ? capacity : index }

    mutating func reset() {
        for i in 0..<buffer.count { buffer[i] = .zero }
        index = 0
        filled = false
    }
}
```

- [ ] **Step 2: Write the sampler body**

Append in the same file:

```swift
/// Drives the engine's `liveTelemetry` `@Published` value at 1 Hz while
/// the engine is `.playing` or `.paused`. Owns no playback state; reads
/// from the engine's existing subsystem counters once per tick and
/// assembles a `LiveTelemetry` snapshot.
///
/// Started from `AetherEngine` at the same lifecycle points as the
/// memprobe task. Stopped in `stopInternal`.
@MainActor
final class LiveTelemetrySampler {
    private weak var engine: AetherEngine?
    private var task: Task<Void, Never>?

    // 10-second rolling windows (10 buckets, 1 second each).
    private var byteWindow = RollingWindow<Int64>(capacity: 10, zero: 0)
    private var frameWindow = RollingWindow<Int>(capacity: 10, zero: 0)

    // Previous-tick snapshots for delta calculation.
    private var lastDemuxerBytes: Int64 = 0
    private var lastFramesEnqueued: Int = 0
    private var sessionStartTime: Date?
    private var sessionStartBytes: Int64 = 0

    init(engine: AetherEngine) {
        self.engine = engine
    }

    func start() {
        stop()
        byteWindow.reset()
        frameWindow.reset()
        lastDemuxerBytes = 0
        lastFramesEnqueued = 0
        sessionStartTime = Date()
        sessionStartBytes = 0
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() {
        guard let engine = engine else { return }

        // ---- Demuxer-driven instant + average bitrate (works on both paths) ----
        let demuxerBytes = engine.demuxerBytesFetched
        let bytesThisTick = max(0, demuxerBytes - lastDemuxerBytes)
        lastDemuxerBytes = demuxerBytes
        if sessionStartBytes == 0 { sessionStartBytes = demuxerBytes }
        byteWindow.push(bytesThisTick)

        let instantBitrateMbps: Double?
        if byteWindow.count >= 2 {
            let totalBytes = byteWindow.sum
            let seconds = Double(byteWindow.count)
            instantBitrateMbps = Double(totalBytes) * 8.0 / seconds / 1_000_000.0
        } else {
            instantBitrateMbps = nil
        }

        let averageBitrateMbps: Double?
        if let start = sessionStartTime {
            let elapsed = max(0.5, Date().timeIntervalSince(start))
            let lifetimeBytes = max(0, demuxerBytes - sessionStartBytes)
            averageBitrateMbps = Double(lifetimeBytes) * 8.0 / elapsed / 1_000_000.0
        } else {
            averageBitrateMbps = nil
        }

        // ---- Per-path FPS, dropped frames, network, sync gap ----
        let observedFps: Double?
        let droppedFrameCount: Int?
        let networkThroughputMbps: Double?
        let networkTransferredBytes: Int64?
        let avSyncGapMs: Double?
        let forwardBufferSeconds: Double?

        switch engine.playbackBackend {
        case .native:
            observedFps = nil
            if let item = engine.currentAVPlayer?.currentItem,
               let event = item.accessLog()?.events.last {
                droppedFrameCount = event.numberOfDroppedVideoFrames >= 0
                    ? event.numberOfDroppedVideoFrames : nil
                let observed = event.observedBitrate
                networkThroughputMbps = observed.isFinite && observed > 0
                    ? observed / 1_000_000.0 : nil
                networkTransferredBytes = event.numberOfBytesTransferred >= 0
                    ? Int64(event.numberOfBytesTransferred) : nil
            } else {
                droppedFrameCount = nil
                networkThroughputMbps = nil
                networkTransferredBytes = nil
            }
            avSyncGapMs = nil
            forwardBufferSeconds = Self.computeNativeForwardBuffer(engine: engine)

        case .software:
            let frames = engine.softwareHostFramesEnqueued
            let framesThisTick = max(0, frames - lastFramesEnqueued)
            lastFramesEnqueued = frames
            frameWindow.push(framesThisTick)
            if frameWindow.count >= 2 {
                let totalFrames = frameWindow.sum
                let seconds = Double(frameWindow.count)
                observedFps = Double(totalFrames) / seconds
            } else {
                observedFps = nil
            }
            droppedFrameCount = nil
            // Software path: same source as instant bitrate (the
            // demuxer pulls the same bytes off the network).
            networkThroughputMbps = instantBitrateMbps
            networkTransferredBytes = demuxerBytes
            avSyncGapMs = engine.lastAVGapMs
            forwardBufferSeconds = nil  // software host has no comparable surface yet

        case .aether, .none:
            observedFps = nil
            droppedFrameCount = nil
            networkThroughputMbps = nil
            networkTransferredBytes = nil
            avSyncGapMs = nil
            forwardBufferSeconds = nil
        }

        // ---- Engine diagnostics (always populated, cheap) ----
        let snapshot = LiveTelemetry(
            instantBitrateMbps: instantBitrateMbps,
            averageBitrateMbps: averageBitrateMbps,
            observedFps: observedFps,
            droppedFrameCount: droppedFrameCount,
            forwardBufferSeconds: forwardBufferSeconds,
            cachedBytes: engine.cachedBytes,
            networkThroughputMbps: networkThroughputMbps,
            networkTransferredBytes: networkTransferredBytes,
            avSyncGapMs: avSyncGapMs,
            producerRestartCount: engine.producerRestartCount,
            muxedBytesLifetime: engine.muxedBytesLifetime,
            serverBytesSentLifetime: engine.serverBytesSentLifetime,
            serverRequestCount: engine.serverRequestCount,
            demuxerBytesFetched: demuxerBytes,
            audioBridgeLiveBytes: engine.audioBridgeLiveBytes,
            rssMb: AetherEngine.residentMemoryMB()
        )
        engine.liveTelemetry = snapshot
    }

    private static func computeNativeForwardBuffer(engine: AetherEngine) -> Double? {
        guard let player = engine.currentAVPlayer,
              let item = player.currentItem else { return nil }
        let ranges = item.loadedTimeRanges
        guard let last = ranges.last?.timeRangeValue else { return nil }
        let end = CMTimeGetSeconds(CMTimeAdd(last.start, last.duration))
        let now = CMTimeGetSeconds(player.currentTime())
        guard end.isFinite, now.isFinite else { return nil }
        return max(0, end - now)
    }
}
```

- [ ] **Step 3: Confirm `LiveTelemetrySampler.swift` references compile**

Run: `cd ~/Dev/AetherEngine && swift build`
Expected: **fail** with missing properties on `AetherEngine` — `demuxerBytesFetched`, `cachedBytes`, `softwareHostFramesEnqueued`, `producerRestartCount`, `muxedBytesLifetime`, `serverBytesSentLifetime`, `serverRequestCount`, `audioBridgeLiveBytes`, `lastAVGapMs`, `liveTelemetry`, `currentAVPlayer`.
This is intentional. Task 6 wires those up.

- [ ] **Step 4: Stage and stop (don't commit yet — wire-up follows)**

Do not commit this task on its own. The next task adds the wire-up; commit both together when the build is green.

---

### Task 6: Wire the sampler into AetherEngine

**Files:**
- Modify: `Sources/AetherEngine/AetherEngine.swift`

- [ ] **Step 1: Add the `@Published` surface**

Open `Sources/AetherEngine/AetherEngine.swift`. Find the block of `@Published` properties around lines 56 - 113. Just below the `videoFormat` and `playbackBackend` declarations (around line 77 — `@Published public private(set) var playbackBackend: PlaybackBackend = .none`), add:

```swift
    /// 1 Hz snapshot of live playback telemetry while the engine is
    /// `.playing` or `.paused`. `nil` while idle. Driven by
    /// `LiveTelemetrySampler`. The host's stats overlay subscribes to
    /// this and renders into the Live + Engine Diagnostics sections.
    @Published public private(set) var liveTelemetry: LiveTelemetry?
```

- [ ] **Step 2: Add the sampler instance + bridge accessors**

Near the `memoryProbeTask` declaration (around line 248), add:

```swift
    private var liveTelemetrySampler: LiveTelemetrySampler?
```

The sampler reads from several subsystems. The engine already has public/internal accessors for some; add convenience properties for the rest. Find a spot near the other internal accessors (search the file for `cumulativeBytesFetched` to find an existing forwarder). Add inside the class:

```swift
    /// Bytes the active demuxer has fetched from the source. Mirrors
    /// `Demuxer.cumulativeBytesFetched`. Used by `LiveTelemetrySampler`
    /// for instant + average bitrate.
    var demuxerBytesFetched: Int64 {
        videoEngine?.demuxer?.cumulativeBytesFetched ?? 0
    }

    var cachedBytes: Int64? {
        guard let bytes = videoEngine?.segmentCacheTotalBytes else { return nil }
        return Int64(bytes)
    }

    var softwareHostFramesEnqueued: Int {
        softwareHost?.framesEnqueued ?? 0
    }

    var producerRestartCount: Int {
        videoEngine?.producerRestartCount ?? 0
    }

    var muxedBytesLifetime: Int64 {
        videoEngine?.muxedBytesLifetime ?? 0
    }

    var serverBytesSentLifetime: Int64 {
        Int64(videoEngine?.serverLifetimeBytesSent ?? 0)
    }

    var serverRequestCount: Int {
        videoEngine?.serverRequestCount ?? 0
    }

    var audioBridgeLiveBytes: Int {
        videoEngine?.audioBridgeLiveBytes ?? 0
    }

    var lastAVGapMs: Double {
        videoEngine?.lastAVGapMs ?? 0
    }
```

If any of those forwarders doesn't have a matching accessor on `HLSVideoEngine`, add the trivial forwarder there too. Use grep to confirm — e.g.:

```bash
grep -n "var producerRestartCount\|var muxedBytesLifetime\|var segmentCacheTotalBytes\|var serverLifetimeBytesSent\|var serverRequestCount\|var audioBridgeLiveBytes\|var lastAVGapMs" Sources/AetherEngine/Video/HLSVideoEngine.swift
```

For each missing one, add a one-line accessor on `HLSVideoEngine` that reads from the underlying subsystem (e.g. `var serverRequestCount: Int { server?.requestCount ?? 0 }`).

- [ ] **Step 3: Start + stop the sampler at the same hooks as the memprobe**

Search `Sources/AetherEngine/AetherEngine.swift` for `startMemoryProbe`. There are two start sites (around lines 647 and 686) and one stop site (around line 1540, inside `stopInternal`).

At each `startMemoryProbe()` call, add immediately after:

```swift
                startLiveTelemetrySampler()
```

At the stop site near line 1540, just below `memoryProbeTask?.cancel()` / `memoryProbeTask = nil`, add:

```swift
        liveTelemetrySampler?.stop()
        liveTelemetrySampler = nil
        liveTelemetry = nil
```

Near `startMemoryProbe()` (around line 1587), add a sibling helper:

```swift
    private func startLiveTelemetrySampler() {
        liveTelemetrySampler?.stop()
        let sampler = LiveTelemetrySampler(engine: self)
        liveTelemetrySampler = sampler
        sampler.start()
    }
```

- [ ] **Step 4: Compile**

Run: `cd ~/Dev/AetherEngine && swift build`
Expected: succeeds.

If a forwarder name on `HLSVideoEngine` is missing (compiler reports `value of type 'HLSVideoEngine' has no member 'X'`), open that file and add the trivial accessor as described in Step 2.

- [ ] **Step 5: Commit Tasks 5 + 6 together**

```bash
cd ~/Dev/AetherEngine
git add Sources/AetherEngine/Diagnostics/LiveTelemetrySampler.swift \
        Sources/AetherEngine/AetherEngine.swift \
        Sources/AetherEngine/Video/HLSVideoEngine.swift
git commit -m "$(cat <<'EOF'
feat(diagnostics): 1 Hz LiveTelemetry sampler with native + software path coverage

Adds @Published liveTelemetry on AetherEngine plus a sampler task
that runs alongside the existing memprobe. Native path reads dropped
frames + observed bitrate + transferred bytes from
AVPlayerItemAccessLog; software path reads framesEnqueued + last AV
gap from the engine's own counters. Common counters (demuxer bytes,
cache bytes, server bytes, mux bytes, audio bridge bytes, RSS, producer
restart count) populate the diagnostics section on both paths.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: AetherEngine smoke check + push

- [ ] **Step 1: Full build**

```bash
cd ~/Dev/AetherEngine && swift build 2>&1 | tail -40
```

Expected: succeeds. If there are warnings about unused `_requestCount` or similar, they are fine to leave.

- [ ] **Step 2: Push**

```bash
cd ~/Dev/AetherEngine && git push
```

Expected: pushes all four commits from Tasks 1 - 6 to origin/main.

---

## Phase 2 — Sodalite UI + settings + engine bump

Working dir for all Phase 2 tasks: `/Users/vincentherbst/Dev/Sodalite`

### Task 8: Bump AetherEngine pin

- [ ] **Step 1: Run the bump script**

```bash
cd ~/Dev/Sodalite && Scripts/bump-engine.sh
```

Expected: the script reads `origin/main`'s latest SHA, updates `Sodalite.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, runs `xcodebuild -resolvePackageDependencies`, commits as `chore(deps): bump AetherEngine to <sha> — <subject>`, and pushes.

If the script is missing or fails, do it manually: grab the SHA from `cd ~/Dev/AetherEngine && git rev-parse origin/main`, edit `Package.resolved`, then run `xcodebuild -resolvePackageDependencies -project Sodalite.xcodeproj -scheme Sodalite`, commit, push.

- [ ] **Step 2: Confirm new symbols are visible**

```bash
cd ~/Dev/Sodalite
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep -E "(error:|warning:)" | head -20
```

Expected: clean compile. The new `LiveTelemetry` type and the `liveTelemetry` publisher are visible from Sodalite code paths but not yet referenced.

---

### Task 9: Add `showEngineDiagnostics` preference

**Files:**
- Modify: `Sodalite/Features/Settings/PlaybackPreferences.swift`

- [ ] **Step 1: Add the storage key**

Find the `Keys` namespace around line 46. Add directly under `static let showStatsForNerds`:

```swift
        static let showEngineDiagnostics = "playback.showEngineDiagnostics"
```

- [ ] **Step 2: Add the property + load**

Find `var showStatsForNerds: Bool` around line 368. Add directly below:

```swift
    var showEngineDiagnostics: Bool {
        didSet { store.set(showEngineDiagnostics, forKey: Keys.showEngineDiagnostics) }
    }
```

Then find the initialiser around line 467 (`self.showStatsForNerds = store.object(forKey: Keys.showStatsForNerds) as? Bool ?? false`). Add directly below:

```swift
        self.showEngineDiagnostics = store.object(forKey: Keys.showEngineDiagnostics) as? Bool ?? false
```

- [ ] **Step 3: Compile + commit**

```bash
cd ~/Dev/Sodalite
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | tail -5
git add Sodalite/Features/Settings/PlaybackPreferences.swift
git commit -m "$(cat <<'EOF'
feat(stats): add showEngineDiagnostics preference

Persisted in CloudSync alongside showStatsForNerds. Gates the deeper
Engine/Buffer/Network sections of the stats overlay; off by default
so the addition is invisible to casual users.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Wire the new toggle into Settings UI

**Files:**
- Modify: `Sodalite/Features/Settings/PlaybackSettingsView.swift`

- [ ] **Step 1: Add the nested toggle**

Find the existing Stats for Nerds toggle around line 232. Read 20 lines of context above and below to see the row layout pattern. Just after the closing brace of that toggle's `Toggle(...)` block, add a second toggle inside the same `Section` or `Group`:

```swift
                    Toggle(isOn: Binding(
                        get: { prefs.showEngineDiagnostics },
                        set: { prefs.showEngineDiagnostics = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.playback.engineDiagnostics.title")
                            Text("settings.playback.engineDiagnostics.subtitle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!prefs.showStatsForNerds)
                    .padding(.leading, 24)
```

The exact wrapper (`VStack`, `Toggle`, etc.) should match what the existing `showStatsForNerds` toggle uses. If that toggle uses a custom row helper (e.g. a `PlaybackToggleRow` view in the same file), call the same helper and pass the diagnostic strings. Read lines 225 - 250 to confirm.

- [ ] **Step 2: Compile**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep -E "error:" | head -10
```

Expected: no errors. (Two localisation warnings about the missing strings are expected — Task 13 adds them.)

- [ ] **Step 3: Commit**

```bash
git add Sodalite/Features/Settings/PlaybackSettingsView.swift
git commit -m "$(cat <<'EOF'
feat(stats): expose Engine Diagnostics toggle in Playback settings

Nested under Stats for Nerds, disabled when the parent is off. Strings
land in Localizable.xcstrings in a follow-up commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Extend `statsSectionAnchors` + `availableStatsSectionIndices`

**Files:**
- Modify: `Sodalite/Player/PlayerViewModel.swift`
- Modify: `Sodalite/Player/PlayerView.swift`

- [ ] **Step 1: Extend the static anchor list**

Open `Sodalite/Player/PlayerViewModel.swift`. Find `static let statsSectionAnchors` around line 106. Replace with:

```swift
    static let statsSectionAnchors: [String] = [
        "stats.section.live",       // 0 — always shown when stats on
        "stats.section.playback",   // 1
        "stats.section.video",      // 2
        "stats.section.audio",      // 3
        "stats.section.subtitle",   // 4
        "stats.section.file",       // 5
        "stats.section.engine",     // 6 — gated by showEngineDiagnostics
        "stats.section.buffer",     // 7 — gated by showEngineDiagnostics
        "stats.section.network",    // 8 — gated by showEngineDiagnostics
    ]
```

The previous mapping (0 = playback … 4 = file) becomes (1 = playback … 5 = file).

- [ ] **Step 2: Update `availableStatsSectionIndices`**

Open `Sodalite/Player/PlayerView.swift`. Find `private var availableStatsSectionIndices: [Int]` around line 792. Replace the body with:

```swift
    private var availableStatsSectionIndices: [Int] {
        var indices: [Int] = []
        // 0 — Live is always rendered (the panel only appears when stats are on).
        indices.append(0)
        // 1 — Playback (always)
        indices.append(1)
        let item = viewModel.item
        if item.mediaStreams?.contains(where: { $0.type == .video }) == true {
            indices.append(2)
        }
        let hasEngineAudio = viewModel.player.audioTracks.contains {
            $0.id == viewModel.player.activeAudioTrackIndex
        }
        let hasJellyfinAudio = item.mediaStreams?.contains(where: { $0.type == .audio }) == true
        if hasEngineAudio || hasJellyfinAudio {
            indices.append(3)
        }
        if viewModel.activeSubtitleIndex != nil {
            indices.append(4)
        }
        if item.mediaSources?.first != nil {
            indices.append(5)
        }
        if viewModel.preferences.showEngineDiagnostics {
            indices.append(6)
            indices.append(7)
            indices.append(8)
        }
        return indices
    }
```

If `viewModel` does not already have a `preferences` accessor, grep for how other code in this file reaches `PlaybackPreferences` (likely via `viewModel.dependencies.playbackPreferences` or `@Environment(\.dependencies)`). Mirror that.

- [ ] **Step 3: Compile + commit**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep "error:" | head
git add Sodalite/Player/PlayerViewModel.swift Sodalite/Player/PlayerView.swift
git commit -m "$(cat <<'EOF'
feat(stats): extend anchor list for Live + Engine Diagnostics sections

statsSectionAnchors now holds nine entries: a new Live anchor at the
top, the existing five static sections, and three diagnostic anchors
appended at the bottom. availableStatsSectionIndices filters the
diagnostic anchors when showEngineDiagnostics is off so up/down
cursor stepping only lands on rendered sections.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Add the new sections to `StatsOverlayView`

**Files:**
- Modify: `Sodalite/Models/Jellyfin/JellyfinItem.swift` (add `bitRate` field to `MediaStream`)
- Modify: `Sodalite/Player/UI/StatsOverlayView.swift`

- [ ] **Step 0: Add `bitRate` to `MediaStream`**

The Jellyfin API returns `BitRate` per stream but Sodalite's `MediaStream` struct currently ignores it. Open `Sodalite/Models/Jellyfin/JellyfinItem.swift`. Find `struct MediaStream` around line 242. Add this property in the same `let` block (e.g. just below `profile: String?`):

```swift
    let bitRate: Int?
```

And add the matching `CodingKey` entry (e.g. after `case profile = "Profile"`):

```swift
        case bitRate = "BitRate"
```

This is needed for the audio bitrate row in Step 4 below, and also makes a more honest per-stream value available if the Video section later wants stream-specific (vs. container) bitrate.

- [ ] **Step 1: Update the section sequence**

Find the `VStack(alignment: .leading, spacing: 18)` block inside `private var panel` around lines 78 - 100. Replace with:

```swift
                VStack(alignment: .leading, spacing: 18) {
                    Text("player.stats.title")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    liveSection
                        .id(PlayerViewModel.statsSectionAnchors[0])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 0))
                    playbackSection
                        .id(PlayerViewModel.statsSectionAnchors[1])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 1))
                    videoSection
                        .id(PlayerViewModel.statsSectionAnchors[2])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 2))
                    audioSection
                        .id(PlayerViewModel.statsSectionAnchors[3])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 3))
                    subtitleSection
                        .id(PlayerViewModel.statsSectionAnchors[4])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 4))
                    fileSection
                        .id(PlayerViewModel.statsSectionAnchors[5])
                        .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 5))
                    if showEngineDiagnostics {
                        engineSection
                            .id(PlayerViewModel.statsSectionAnchors[6])
                            .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 6))
                        bufferSection
                            .id(PlayerViewModel.statsSectionAnchors[7])
                            .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 7))
                        networkSection
                            .id(PlayerViewModel.statsSectionAnchors[8])
                            .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == 8))
                    }
                }
                .padding(28)
                .frame(width: 560, alignment: .topLeading)
```

- [ ] **Step 2: Add the `showEngineDiagnostics` prop**

Find the existing prop list at the top of `StatsOverlayView` (lines 21 - 30). Add a new `let`:

```swift
    /// Whether to render the Engine/Buffer/Network diagnostic sections
    /// at the bottom of the panel. Driven by
    /// `PlaybackPreferences.showEngineDiagnostics`.
    let showEngineDiagnostics: Bool
```

- [ ] **Step 3: Add the new `liveSection`**

Below the existing `private var playbackSection: some View { ... }` block (insert before it, since Live is rendered first), add:

```swift
    @ViewBuilder
    private var liveSection: some View {
        section("player.stats.section.live") {
            let telemetry = player.liveTelemetry
            // Bitrate (instant + average)
            row(
                "player.stats.bitrate",
                value: Self.formatBitratePair(
                    instant: telemetry?.instantBitrateMbps,
                    average: telemetry?.averageBitrateMbps
                )
            )
            // Buffer (seconds + cached MB)
            row(
                "player.stats.buffer",
                value: Self.formatBufferPair(
                    seconds: telemetry?.forwardBufferSeconds,
                    cachedBytes: telemetry?.cachedBytes
                )
            )
            // Network (throughput + transferred bytes)
            row(
                "player.stats.network",
                value: Self.formatNetworkPair(
                    mbps: telemetry?.networkThroughputMbps,
                    transferred: telemetry?.networkTransferredBytes
                )
            )
            if let dropped = telemetry?.droppedFrameCount {
                row("player.stats.droppedFrames", value: "\(dropped)")
            }
            if let fps = telemetry?.observedFps {
                row("player.stats.fpsObserved", value: String(format: "%.2f fps", fps))
            }
            if let gap = telemetry?.avSyncGapMs {
                row("player.stats.avGap", value: Self.formatAVGap(gap))
            }
        }
    }
```

- [ ] **Step 3b: Extend the existing `audioSection` with a bitrate row**

Find `private var audioSection: some View` in `StatsOverlayView.swift` (around line 184 of the existing file). Inside the existing `section("detail.tech.audio") { ... }` block, add a bitrate row after the channels row and before the language row. Use the `engineTrack` / `activeAudioStream` fallback pattern the rest of the section already uses:

```swift
                let bitrate = engineTrack?.bitrate ?? activeAudioStream?.bitRate
                if let bps = bitrate, bps > 0 {
                    row("detail.tech.bitrate", value: Self.formatBitrate(bps))
                }
```

Two notes:
1. `engineTrack?.bitrate` reads from AetherEngine's `TrackInfo.bitrate`. If `TrackInfo` doesn't have a `bitrate` field yet, drop the `engineTrack?.bitrate ??` prefix — the Jellyfin-side `bitRate` is enough for now. (Check by greping the engine: `grep "bitrate\|let bitrate" ~/Dev/AetherEngine/Sources/AetherEngine/PlayerState.swift`)
2. `Self.formatBitrate` already exists in `StatsOverlayView` (used by the video section); reuse it.
3. The localisation key `detail.tech.bitrate` already exists from the video section, no new key needed.

This is the audio bitrate addition that wasn't in the original spec; included here because Jellyfin reliably reports per-audio-stream bitrate and surfacing it next to channels reads as obviously useful.

- [ ] **Step 4: Add the three diagnostic sections**

Insert below `fileSection`:

```swift
    @ViewBuilder
    private var engineSection: some View {
        if let telemetry = player.liveTelemetry {
            section("player.stats.section.engine") {
                row("player.stats.producerRestarts", value: "\(telemetry.producerRestartCount)")
                row("player.stats.rss", value: "\(telemetry.rssMb) MB")
            }
        }
    }

    @ViewBuilder
    private var bufferSection: some View {
        if let telemetry = player.liveTelemetry {
            section("player.stats.section.buffer") {
                row(
                    "player.stats.demuxerBytes",
                    value: Self.formatByteCount(telemetry.demuxerBytesFetched)
                )
                row(
                    "player.stats.muxedBytes",
                    value: Self.formatByteCount(telemetry.muxedBytesLifetime)
                )
                row(
                    "player.stats.audioBridge",
                    value: Self.formatByteCountShort(telemetry.audioBridgeLiveBytes)
                )
            }
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        if let telemetry = player.liveTelemetry {
            section("player.stats.section.network") {
                row(
                    "player.stats.serverSent",
                    value: Self.formatByteCount(telemetry.serverBytesSentLifetime)
                )
                row(
                    "player.stats.serverRequests",
                    value: "\(telemetry.serverRequestCount)"
                )
            }
        }
    }
```

- [ ] **Step 5: Add the formatter helpers**

Below the existing `formatFileSize` static helper, add:

```swift
    private static func formatBitratePair(instant: Double?, average: Double?) -> String {
        let inst = instant.map { String(format: "%.1f Mbps", $0) } ?? "—"
        let avg = average.map { String(format: "%.1f", $0) } ?? "—"
        return "\(inst)  ·  avg \(avg) Mbps"
    }

    private static func formatBufferPair(seconds: Double?, cachedBytes: Int64?) -> String {
        let sec = seconds.map { String(format: "+%.1f s", $0) } ?? "—"
        let mb = cachedBytes.map { String(format: "%d MB", $0 / 1_048_576) } ?? "—"
        return "\(sec)  ·  \(mb) cached"
    }

    private static func formatNetworkPair(mbps: Double?, transferred: Int64?) -> String {
        let m = mbps.map { String(format: "%.1f Mbps", $0) } ?? "—"
        let t = transferred.map { Self.formatByteCount($0) } ?? "—"
        return "\(m)  ·  \(t)"
    }

    private static func formatAVGap(_ ms: Double) -> String {
        return String(format: "%.0f ms", ms)
    }

    private static func formatByteCount(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    private static func formatByteCountShort(_ bytes: Int) -> String {
        return formatByteCount(Int64(bytes))
    }
```

- [ ] **Step 6: Update the call-site in PlayerView.swift**

Open `Sodalite/Player/PlayerView.swift`, find around line 1500 - 1520 where `StatsOverlayView(...)` is instantiated (search for `scrollSectionIndex: viewModel.statsSectionIndex`). Add the new prop to the instantiation:

```swift
                StatsOverlayView(
                    player: viewModel.player,
                    item: viewModel.item,
                    activeSubtitleIndex: viewModel.activeSubtitleIndex,
                    scrollSectionIndex: viewModel.statsSectionIndex,
                    showEngineDiagnostics: viewModel.preferences.showEngineDiagnostics
                )
```

The exact existing init line shape will dictate parameter naming; mirror it.

- [ ] **Step 7: Compile**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep "error:" | head -20
```

Expected: zero errors. Several localisation warnings (untranslated keys) are expected; Task 13 resolves them.

- [ ] **Step 8: Commit**

```bash
git add Sodalite/Player/UI/StatsOverlayView.swift Sodalite/Player/PlayerView.swift
git commit -m "$(cat <<'EOF'
feat(stats): render Live + Engine Diagnostics sections in the overlay

Live section subscribes to AetherEngine.liveTelemetry and shows
instant + avg bitrate, forward buffer + cached MB, network
throughput + lifetime bytes, plus path-conditional rows for dropped
frames (native), observed FPS (software), and A/V sync gap
(software). Engine, Buffer, and Network sections render only when
showEngineDiagnostics is on.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Localisation keys

**Files:**
- Modify: `Sodalite/Localizable.xcstrings`

- [ ] **Step 1: Catalogue the new keys**

The new strings introduced by Tasks 10 and 12:

```
settings.playback.engineDiagnostics.title
settings.playback.engineDiagnostics.subtitle
player.stats.section.live
player.stats.section.engine
player.stats.section.buffer
player.stats.section.network
player.stats.bitrate
player.stats.buffer
player.stats.network
player.stats.droppedFrames
player.stats.fpsObserved
player.stats.avGap
player.stats.producerRestarts
player.stats.rss
player.stats.demuxerBytes
player.stats.muxedBytes
player.stats.audioBridge
player.stats.serverSent
player.stats.serverRequests
```

- [ ] **Step 2: Add entries — open the file in Xcode**

Open `Sodalite.xcodeproj` in Xcode, select `Localizable.xcstrings`, and add each key by typing into the Key column. Xcode will create the entry in the right format. Translate at minimum the source language (English) and German; let the other 24 locales fall back to English on first ship and back-fill in a follow-up commit.

If editing the JSON directly:

1. First check Xcode's exact spacing format by reading the existing `player.stats.title` entry:

```bash
grep -B1 -A 30 '"player.stats.title"' Sodalite/Localizable.xcstrings | head -40
```

2. For each new key, splice an entry that matches that exact format (the `"key" : {` with the space before colon — see CLAUDE.md). If splicing programmatically, run the sed normaliser after:

```bash
sed -i '' 's/"\([^"]*\)": {/"\1" : {/g' Sodalite/Localizable.xcstrings
```

Suggested English values:

| Key | English |
|-----|---------|
| settings.playback.engineDiagnostics.title | Engine Diagnostics |
| settings.playback.engineDiagnostics.subtitle | Adds buffer, network, and subsystem counters. For troubleshooting. |
| player.stats.section.live | Live |
| player.stats.section.engine | Engine |
| player.stats.section.buffer | Buffer |
| player.stats.section.network | Network |
| player.stats.bitrate | Bitrate |
| player.stats.buffer | Buffer |
| player.stats.network | Network |
| player.stats.droppedFrames | Dropped Frames |
| player.stats.fpsObserved | FPS |
| player.stats.avGap | A/V Gap |
| player.stats.producerRestarts | Producer Restarts |
| player.stats.rss | Memory (RSS) |
| player.stats.demuxerBytes | Demuxer Bytes |
| player.stats.muxedBytes | Muxed Bytes |
| player.stats.audioBridge | Audio Bridge |
| player.stats.serverSent | Server Sent |
| player.stats.serverRequests | Server Requests |

Suggested German values:

| Key | German |
|-----|--------|
| settings.playback.engineDiagnostics.title | Engine-Diagnose |
| settings.playback.engineDiagnostics.subtitle | Zeigt Buffer-, Netzwerk- und Subsystem-Zähler. Für Troubleshooting. |
| player.stats.section.live | Live |
| player.stats.section.engine | Engine |
| player.stats.section.buffer | Buffer |
| player.stats.section.network | Netzwerk |
| player.stats.bitrate | Bitrate |
| player.stats.buffer | Buffer |
| player.stats.network | Netzwerk |
| player.stats.droppedFrames | Verlorene Frames |
| player.stats.fpsObserved | FPS |
| player.stats.avGap | A/V-Versatz |
| player.stats.producerRestarts | Producer-Restarts |
| player.stats.rss | Speicher (RSS) |
| player.stats.demuxerBytes | Demuxer-Bytes |
| player.stats.muxedBytes | Muxer-Bytes |
| player.stats.audioBridge | Audio-Bridge |
| player.stats.serverSent | Gesendet |
| player.stats.serverRequests | Anfragen |

- [ ] **Step 3: Compile + check warnings**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep -i "string\|localiz" | head -10
```

Expected: localisation warnings about untranslated keys for the other 24 locales are OK (they fall back to English). No errors.

- [ ] **Step 4: Commit**

```bash
git add Sodalite/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
i18n(stats): add keys for Live + Engine Diagnostics sections

English + German for the new stats overlay sections and the Engine
Diagnostics settings toggle. Other locales fall back to English on
first ship.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: A/V gap color-coding

**Files:**
- Modify: `Sodalite/Player/UI/StatsOverlayView.swift`

- [ ] **Step 1: Add a colored value variant of the row helper**

Below the existing `row(_:value:)` helper, add:

```swift
    private func row(
        _ labelKey: LocalizedStringKey,
        value: String,
        valueColor: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(labelKey)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 180, alignment: .leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.caption)
                .foregroundStyle(valueColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
```

- [ ] **Step 2: Use it for the A/V gap row**

In `liveSection`, replace:

```swift
            if let gap = telemetry?.avSyncGapMs {
                row("player.stats.avGap", value: Self.formatAVGap(gap))
            }
```

with:

```swift
            if let gap = telemetry?.avSyncGapMs {
                row(
                    "player.stats.avGap",
                    value: Self.formatAVGap(gap),
                    valueColor: Self.avGapColor(gap)
                )
            }
```

Add the helper next to `formatAVGap`:

```swift
    private static func avGapColor(_ ms: Double) -> Color {
        let abs = Swift.abs(ms)
        if abs < 50 { return .green }
        if abs < 150 { return .yellow }
        return .red
    }
```

- [ ] **Step 3: Compile + commit**

```bash
xcodebuild -project Sodalite.xcodeproj -scheme Sodalite \
    -destination 'generic/platform=tvOS' \
    build 2>&1 | grep "error:" | head
git add Sodalite/Player/UI/StatsOverlayView.swift
git commit -m "$(cat <<'EOF'
feat(stats): colour-code A/V gap row by threshold

Green under 50 ms, yellow under 150 ms, red above. Matches the
threshold the engine already uses to warn-log the gap.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 15: Manual verification

The codebase has no test target. Verification is run by hand on a real device.

- [ ] **Step 1: Run on Apple TV (or simulator)**

Open in Xcode, pick the `Sodalite` scheme + Apple TV destination, run.

- [ ] **Step 2: Pre-checks**

- Open Settings → Playback. Confirm the Stats for Nerds row shows two toggles: the original + a nested "Engine Diagnostics" that is disabled when the parent is off.
- Turn both toggles on.

- [ ] **Step 3: Native-path check (HEVC/H.264)**

Play any 4K HEVC HDR file. Open the player UI, press the info chip.

- Confirm the Live section appears with: Bitrate (e.g. `24.3 Mbps  ·  avg 22.1 Mbps`), Buffer (`+18.4 s  ·  47 MB cached`), Network, Dropped Frames (`0`).
- Confirm FPS and A/V Gap rows are absent (native path, fields are nil).
- Confirm Engine, Buffer, Network sections appear below File with non-zero values.
- Up/Down arrows step through all 9 anchors.
- Toggle Engine Diagnostics off from Settings, return to player, reopen overlay. Confirm bottom three sections disappear and Up/Down only steps 6 anchors.

- [ ] **Step 4: Software-path check (AV1 without HW decode)**

Play an AV1 file that lacks hardware decode (e.g. tvOS 26 on Apple TV 4K Gen 1, or any AV1 file on the iOS simulator).

- Confirm the FPS row shows a live number near the source's declared frame rate.
- Confirm the A/V Gap row appears with a colored value (green during steady-state).
- Confirm Dropped Frames row is absent (software path, field is nil).

- [ ] **Step 5: Edge cases**

- Scrub mid-playback. Confirm Bitrate dips for 1 to 2 seconds, then recovers.
- Switch audio track mid-playback. Confirm Live section flickers nil for one tick.
- Pause for 30 seconds. Confirm Instant Bitrate drops to zero, Average Bitrate stays.
- Quit and restart. Confirm both toggles persist their setting.

- [ ] **Step 6: Final push**

```bash
cd ~/Dev/Sodalite && git push
```

Expected: pushes all Phase 2 commits.

---

### Task 16: Close issue #8 update + GitHub Release note draft

- [ ] **Step 1: Post a follow-up comment on Sodalite issue #8**

```bash
gh issue comment 8 --repo superuser404notfound/Sodalite --body "$(cat <<'EOF'
Follow-up shipped: live telemetry expansion of the Stats for Nerds overlay.

Sodalite commits in this branch, AetherEngine commits in the corresponding `chore(deps): bump AetherEngine` commit.

**Live section (always visible when stats on):**
- Bitrate, instant + lifetime average, from the demuxer's actual byte rate (works on both backends)
- Buffer, forward seconds + cached MB
- Network throughput + transferred bytes
- Dropped Frames on the native backend (AVPlayerItemAccessLog)
- Observed FPS on the software backend (dav1d enqueue rate)
- A/V Gap on the software backend, colour-coded (green / yellow / red)

**Engine Diagnostics section (new opt-in toggle in Settings, off by default):**
- Producer Restarts, RSS
- Demuxer Bytes, Muxed Bytes, Audio Bridge live bytes
- Server Sent, Server Requests

All values refresh at 1 Hz from a new `LiveTelemetry` surface on AetherEngine. Mid-stream resolution updates for software AV1/VP9 are still deferred as before; no real-world repro yet.
EOF
)"
```

- [ ] **Step 2: Draft a Release note for the next version bump**

When the next `gh release create` happens, include a section like:

```markdown
### Stats for Nerds, Live Section

The player's optional Stats for Nerds overlay now shows live values: bitrate (instant + average), buffer health, network throughput, dropped frames or observed FPS depending on the decode path, and an A/V sync gap indicator.

A second toggle under Settings → Playback → Stats for Nerds adds an "Engine Diagnostics" deep-dive section for troubleshooting, off by default.
```

---

## Self-Review

Done. Inline corrections noted:

- Task 2 originally assumed `lastAVGapMs` was already on the engine; the spec said so, but the codebase has the gap measurement inline in HLSSegmentProducer with no stored field. Task 2 now adds the storage explicitly and Task 6 forwards it.
- Task 11 originally was a single change; split into ViewModel + View edits because both files need updating.
- Task 13 lists each new localisation key explicitly, plus suggested English + German values, so the engineer does not have to derive them from earlier tasks.
- All `Self.format*` helpers introduced in Task 12 are defined in the same task.
- The bump-engine script in Task 8 matches the convention in CLAUDE.md.

No outstanding placeholders, no out-of-order type references, no spec requirements without a task.
