import Foundation
import AetherEngine

/// Decides whether a stalled session is stalled because the SERVER is gone, as opposed to a slow link, a
/// rate-limited origin or a dead transcode on a server that is still up.
///
/// The engine cannot answer that question: it knows one URL and a reconnect budget, and its budgets are
/// deliberately generous (an unproductive-reconnect ladder of ~80-100s, then two revives, before
/// `onVODSourceFailed` makes the session terminal, and since AetherEngine 6.33.0 up to 600s per refusal
/// window when the origin answers 429/503/509 rather than failing). The host knows which Jellyfin server
/// this is and can ask it directly, so a dead server becomes a clean error in seconds instead of minutes
/// of spinner.
///
/// Pure state machine, no clock: `SourceOutageWatchdog` owns the timer around it.
struct SourceOutageTracker: Equatable {
    /// Consecutive failed probes before the outage is called. Three at the watchdog's 3s interval put the
    /// verdict roughly 10-15s after the stall began, far inside the engine's own ladder, while still
    /// costing a single transient nothing.
    static let failuresBeforeVerdict = 3

    private(set) var failures = 0
    private(set) var isArmed = false
    private(set) var isActive = true
    private(set) var didCallOutage = false

    /// Whether a probe should be sent right now.
    var wantsProbe: Bool { isArmed && isActive && !didCallOutage }

    /// The reader's network axis entered or left `.stalled`. Leaving disarms and clears the streak:
    /// whatever the reader was fighting, it won, and the next stall starts its own case.
    mutating func setStalled(_ stalled: Bool) {
        guard stalled != isArmed else { return }
        isArmed = stalled
        failures = 0
    }

    /// App activity. A backgrounded session keeps playing audio on purpose (AetherEngine#127 grace), so no
    /// verdict may be reached while the app is away, and the streak restarts on return rather than
    /// resuming: failures counted before the pause say nothing about the link now.
    mutating func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        failures = 0
    }

    /// Folds one probe result in. Returns true exactly once, on the probe that calls the outage.
    mutating func recordProbe(succeeded: Bool) -> Bool {
        guard wantsProbe else { return false }
        guard !succeeded else {
            failures = 0
            return false
        }
        failures += 1
        guard failures >= Self.failuresBeforeVerdict else { return false }
        didCallOutage = true
        return true
    }

    /// Back to square one for a retried session.
    mutating func reset() {
        self = SourceOutageTracker(isActive: isActive)
    }

    init() {}

    private init(isActive: Bool) {
        self.isActive = isActive
    }
}

/// Runs `SourceOutageTracker` against the live session: watches the engine's phase, probes the Jellyfin
/// server while the reader is stalled, and calls `onOutage` once the server is confirmed gone.
///
/// The probe arrives as a closure rather than a service dependency so the player stays testable and so the
/// caller decides which base URL counts as "the server" (the active route, which is the one the stream
/// came from).
@MainActor
final class SourceOutageWatchdog {
    /// Gap between probes. Long enough that a stall which resolves itself is never probed twice, short
    /// enough that a dead server is called before the viewer reaches for the remote.
    static let probeInterval: TimeInterval = 3

    private var tracker = SourceOutageTracker()
    private var loop: Task<Void, Never>?
    /// Fences a finishing loop against the handle of the one that replaced it: without it a loop that
    /// exits after a `cancel()` + re-arm clears the NEW handle, and the next arm starts a second prober.
    private var generation = 0
    private let interval: TimeInterval
    private let probe: @Sendable () async -> Bool
    private let onOutage: @MainActor () -> Void

    init(interval: TimeInterval = SourceOutageWatchdog.probeInterval,
         probe: @escaping @Sendable () async -> Bool,
         onOutage: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.probe = probe
        self.onOutage = onOutage
    }

    deinit { loop?.cancel() }

    func phaseChanged(to phase: PlaybackPhase) {
        if case .stalled = phase {
            tracker.setStalled(true)
        } else {
            tracker.setStalled(false)
        }
        syncLoop()
    }

    func setActive(_ active: Bool) {
        tracker.setActive(active)
        syncLoop()
    }

    /// New or retried session: drop the called-outage latch and stop probing until the next stall.
    func reset() {
        tracker.reset()
        syncLoop()
    }

    func cancel() {
        loop?.cancel()
        loop = nil
    }

    private func syncLoop() {
        guard tracker.wantsProbe else {
            cancel()
            return
        }
        guard loop == nil else { return }
        generation &+= 1
        let generation = generation
        loop = Task { [weak self] in
            await self?.run(generation: generation)
        }
    }

    private func run(generation: Int) async {
        while !Task.isCancelled, tracker.wantsProbe {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, tracker.wantsProbe else { break }
            let answered = await probe()
            // The tracker discards a result whose stall is already over; the request outlives the axis it
            // was asked about often enough (2s timeout against a 3s cadence) to matter.
            if tracker.recordProbe(succeeded: answered) {
                onOutage()
                break
            }
        }
        if self.generation == generation { loop = nil }
    }
}
