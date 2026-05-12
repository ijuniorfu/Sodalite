import Foundation
import AVFoundation
import Combine

/// `AVPlayer` + `AVPlayerLayer` wrapper used by the Sodalite player
/// when `PlayerViewModel`'s routing decides a session should go
/// through the native AVKit pipeline. The only reason this path
/// exists at all: tvOS does not expose the HDMI HDR-mode handshake
/// to "Dolby Vision" through `AVSampleBufferDisplayLayer`, only
/// through `AVPlayer`-rooted playback. AetherEngine produces a
/// loopback HLS-fMP4 URL via `startNativeVideoSession(url:)` and
/// this class drives the AVKit side that consumes it.
///
/// Display-criteria handling lives in `PlayerViewModel.applyDisplay
/// Criteria(format:)` (the existing tvOS 17+ path that builds an
/// `AVDisplayCriteria(refreshRate:formatDescription:)` from a
/// HEVC+BT.2020+PQ format description). The host calls that before
/// `load(url:)`, so by the time AVPlayer's first segment fetch
/// reaches the system the HDMI HDR-mode handshake is already in
/// flight.
@MainActor
final class NativeAVPlayer: ObservableObject {

    // MARK: - Published state

    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    @Published private(set) var failureMessage: String?

    // MARK: - Output

    /// The video layer the host mounts in `PlayerView`. Created at
    /// init time and reused for the lifetime of this wrapper, even
    /// across `replaceCurrentItem` swaps.
    let playerLayer: AVPlayerLayer

    /// The underlying `AVPlayer`. Exposed so callers can do things
    /// the published state doesn't cover (`AVMediaSelection` for
    /// audio / subtitle track switching in phase 6).
    let avPlayer: AVPlayer

    // MARK: - Private state

    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var accessLogCount = 0

    /// Monotonic counter so multi-attempt sessions (DrHurt-style
    /// "play, fail, back out, retry") produce distinguishable log
    /// lines. Every load(url:) increments it; every async asset.load
    /// log line tags itself with the current value so a chain of
    /// "asset.load failed" entries can be matched back to the
    /// originating load() invocation.
    private static var nextSessionID: Int = 0
    private var sessionID: Int = 0

    // MARK: - Init

    init() {
        let player = AVPlayer()
        // Default (true) is right for VOD HLS, AVPlayer waits for
        // buffer. HLSAudioEngine sets `false` for live-audio latency
        // reasons, don't copy that pattern here: AVPlayer would try
        // to play the moment seg0 has any bytes and stall because
        // the lazy remuxer needs seconds to produce a full fragment.
        self.avPlayer = player
        self.playerLayer = AVPlayerLayer(player: player)
        self.playerLayer.videoGravity = .resizeAspect
    }

    // No deinit cleanup: under Swift 6 strict concurrency the deinit
    // of a `@MainActor` type is nonisolated and can't reach
    // main-isolated properties. Callers must call `tearDown()`
    // before dropping the wrapper. PlayerViewModel.stopPlayback
    // already does this; PlayerView.viewWillDisappear funnels into
    // the same path.

    // MARK: - Lifecycle

    /// Load the URL produced by `AetherEngine.startNativeVideoSession`.
    /// The display-criteria handshake is the host's responsibility
    /// (call `PlayerViewModel.applyDisplayCriteria` before this) so
    /// AVKit can configure the HDR pipeline against the right target
    /// mode before the first segment is fetched.
    func load(url: URL, startPosition: Double?) {
        unloadCurrentItem()

        Self.nextSessionID += 1
        sessionID = Self.nextSessionID
        let sid = sessionID

        LogTap.shared.note("[NativeAVPlayer] #\(sid) load url=\(url.absoluteString) startPos=\(startPosition.map { String(format: "%.2fs", $0) } ?? "nil")")

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // Match the audio engine's HLSAudioEngine config so any
        // "video-pattern is wrong" hypothesis can be ruled out as we
        // iterate. 4 s of forward buffer matches Apple's HLS authoring
        // recommendation for a 6 s VOD segment cadence: enough to ride
        // out a normal segment-generation hiccup without ballooning
        // resident memory.
        item.preferredForwardBufferDuration = 4.0

        // Forward per-frame HDR metadata (HDR10+ ST 2094-40 and Dolby
        // Vision RPU) from the source bitstream into AVPlayer's
        // display-mode handshake. Without this, AVPlayer renders DV
        // sources in static HDR10 base only — the TV switches to
        // generic HDR mode instead of Dolby Vision mode, and DV
        // tone-mapping curves never engage. DrHurt's tests confirmed
        // that P8 MKVs and DV-tagged MP4s played end-to-end but the
        // Philips TV stayed in HDR mode for DV sources; he flagged
        // the missing AVPlayerItem flag specifically.
        item.appliesPerFrameHDRDisplayMetadata = true
        playerItem = item
        accessLogCount = 0
        failureMessage = nil
        isReady = false

        // Status observer to track readyToPlay / failed transitions.
        // KVO observation runs on the same thread that mutated the
        // observed value, in this case AVPlayerItem hops to its own
        // queue, so we round-trip back to MainActor explicitly.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let statusStr: String
            switch item.status {
            case .unknown:     statusStr = "unknown"
            case .readyToPlay: statusStr = "readyToPlay"
            case .failed:      statusStr = "failed"
            @unknown default:  statusStr = "@unknown"
            }
            let nsErr = item.error as NSError?
            let errSuffix = nsErr.map { " err=\($0.domain)/\($0.code) '\($0.localizedDescription)'" } ?? ""
            LogTap.shared.note("[NativeAVPlayer] #\(sid) item.status=\(statusStr)\(errSuffix)")

            // On .failed, dump the asset's track format descriptions
            // so we can see what codec FourCC AVPlayer actually saw.
            // Targets DrHurt's hev1 / dvhe rejection caveat: if a
            // directURL session fails because the source MP4's
            // sample-entry tag is hev1 instead of hvc1, that shows up
            // here as "video codec='hev1'". Also surfaces the
            // underlying NSError chain which often has the precise
            // CoreMedia / VideoToolbox cause behind the
            // AVFoundationErrorDomain wrapper.
            if item.status == .failed {
                if let nsErr = nsErr,
                   let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
                    LogTap.shared.note("[NativeAVPlayer] #\(sid) item.error.underlying=\(underlying.domain)/\(underlying.code) '\(underlying.localizedDescription)'")
                }
                Self.dumpAssetTracks(item.asset, sid: sid, reason: "item.failed")
            }

            Task { @MainActor in
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                    self.isReady = true
                case .failed:
                    self.failureMessage = item.error?.localizedDescription ?? "AVPlayerItem failed (no description)"
                default:
                    break
                }
            }
        }

        rateObservation = avPlayer.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let rate = player.rate
            LogTap.shared.note("[NativeAVPlayer] #\(sid) rate=\(rate)")
            Task { @MainActor in
                self?.rate = rate
            }
        }

        // timeControlStatus + reasonForWaitingToPlay together explain
        // whether AVPlayer is paused, waiting on buffer, or actively
        // playing. Critical for diagnosing "spinner forever" symptoms
        // because reasonForWaitingToPlay surfaces the exact stall cause
        // (.evaluatingBufferingRate / .toMinimizeStalls / etc.).
        timeControlObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { player, _ in
            let statusStr: String
            switch player.timeControlStatus {
            case .paused:                          statusStr = "paused"
            case .waitingToPlayAtSpecifiedRate:    statusStr = "waitingToPlay"
            case .playing:                         statusStr = "playing"
            @unknown default:                      statusStr = "@unknown"
            }
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "-"
            LogTap.shared.note("[NativeAVPlayer] #\(sid) timeControlStatus=\(statusStr) reason=\(reason)")
        }

        // Error log: AVPlayer surfaces transient HLS-level errors
        // (404 on a segment, parse failure on a manifest, ATS rejection,
        // codec mismatch) without flipping the item to .failed. These
        // are the gold mine for "AVPlayer just sits there" diagnostics.
        let errLogObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let event = self.playerItem?.errorLog()?.events.last else { return }
            let comment = event.errorComment ?? "no comment"
            LogTap.shared.note("[NativeAVPlayer] #\(sid) errorLog code=\(event.errorStatusCode) domain=\(event.errorDomain) uri=\(event.uri ?? "-") '\(comment)'")
        }
        notificationObservers.append(errLogObs)

        // Access log: log only the first few entries so we know
        // whether AVPlayer ever reached the segment-fetch stage.
        // AVPlayer can pump hundreds of these for a long stream so
        // capping at 5 keeps the overlay readable.
        let accessLogObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newAccessLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self,
                  self.accessLogCount < 5,
                  let event = self.playerItem?.accessLog()?.events.last else { return }
            self.accessLogCount += 1
            LogTap.shared.note("[NativeAVPlayer] #\(sid) accessLog uri=\(event.uri ?? "-") server=\(event.serverAddress ?? "-") bytes=\(event.numberOfBytesTransferred) reqs=\(event.numberOfMediaRequests)")
        }
        notificationObservers.append(accessLogObs)

        let failedToEndObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { notification in
            let err = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            let suffix = err.map { " \($0.domain)/\($0.code) '\($0.localizedDescription)'" } ?? ""
            LogTap.shared.note("[NativeAVPlayer] #\(sid) failedToPlayToEndTime\(suffix)")
        }
        notificationObservers.append(failedToEndObs)

        let stalledObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { _ in
            LogTap.shared.note("[NativeAVPlayer] #\(sid) playbackStalled")
        }
        notificationObservers.append(stalledObs)

        // Periodic time observer at 100 ms drives the scrub bar
        // and the resume-position progress reporter. The closure is
        // already invoked on `.main`, so the `MainActor` mutation
        // is safe; cast through a Task to satisfy the Sendable check.
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let value = time.seconds.isFinite ? time.seconds : 0
            Task { @MainActor in
                self?.currentTime = value
            }
        }

        avPlayer.replaceCurrentItem(with: item)

        // Explicitly kick off the async load of the asset's playable /
        // tracks / duration values. AVPlayerItem(asset:) plus KVO on
        // status SHOULD trigger this implicitly per Apple's docs, but
        // the build-123 overlay shows AVPlayer stuck in waitingToPlay
        // with the item never advancing past .unknown — consistent
        // with the asset never beginning its async load. Forcing the
        // load explicitly removes that ambiguity.
        //
        // We load each key in a separate await so DrHurt's
        // "1 success, 3 failures" log signature can be decoded down
        // to "which key is the -1008 hitting on": isPlayable, tracks,
        // or duration. With the batch load they all share one error
        // and we can't tell which probe AVFoundation gave up on.
        let urlStr = url.absoluteString
        Task { [weak self] in
            for key in ["isPlayable", "tracks", "duration"] {
                do {
                    switch key {
                    case "isPlayable": _ = try await asset.load(.isPlayable)
                    case "tracks":     _ = try await asset.load(.tracks)
                    case "duration":   _ = try await asset.load(.duration)
                    default: continue
                    }
                    let detail: String
                    switch key {
                    case "isPlayable": detail = "value=\(asset.isPlayable)"
                    case "tracks":     detail = "count=\(asset.tracks.count)"
                    case "duration":   detail = "seconds=\(asset.duration.seconds)"
                    default: detail = "-"
                    }
                    LogTap.shared.note("[NativeAVPlayer] #\(sid) asset.load(\(key)) ok url=\(urlStr) \(detail)")
                } catch {
                    let nsErr = error as NSError
                    LogTap.shared.note("[NativeAVPlayer] #\(sid) asset.load(\(key)) failed: \(nsErr.domain)/\(nsErr.code) '\(nsErr.localizedDescription)' url=\(urlStr)")
                    if let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
                        LogTap.shared.note("[NativeAVPlayer] #\(sid) asset.load(\(key)) underlying=\(underlying.domain)/\(underlying.code) '\(underlying.localizedDescription)'")
                    }
                    // Dump whatever track info AVFoundation managed
                    // to populate before the load gave up. Targets
                    // DrHurt's -1008 stall: even on failure the
                    // asset's first probe often surfaces the
                    // sample-entry FourCC (hev1 vs hvc1, dvhe vs
                    // dvh1) that explains the rejection.
                    Self.dumpAssetTracks(asset, sid: sid, reason: "asset.load(\(key)).failed")
                    _ = self
                    return
                }
            }
        }

        if let start = startPosition, start > 0 {
            seek(to: start)
        }
    }

    /// Release the AVPlayerItem so a follow-up `load(...)` starts
    /// from a clean state. Does not touch the host window's
    /// display-criteria; that's reset by the host alongside its
    /// existing `resetDisplayCriteria()` flow.
    func tearDown() {
        unloadCurrentItem()
    }

    // MARK: - Playback control

    func play() {
        // AVPlayer with `automaticallyWaitsToMinimizeStalling=true`
        // (the default) handles "play before ready" correctly: it
        // sets rate=1, transitions to waitingToPlayAtSpecifiedRate,
        // begins loading the asset, buffers, and once it has enough
        // it transitions to playing. The earlier defer-until-ready
        // pattern was a guard against a different bug (master playlist
        // parse-rejection) and reintroduced a chicken-and-egg here:
        // item.status doesn't advance until the player is actually
        // told to play, so deferring play() on item.status kept the
        // status stuck at .unknown forever.
        avPlayer.play()
    }

    func pause() {
        avPlayer.pause()
    }

    /// Toggle between play and pause based on the current
    /// `timeControlStatus`. The KVO-observed `rate` is also valid
    /// here but reads as 0 during a buffer stall (which we don't
    /// want to interpret as "paused"); `timeControlStatus`
    /// distinguishes those.
    func toggle() {
        switch avPlayer.timeControlStatus {
        case .playing:
            pause()
        default:
            play()
        }
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        // Frame-accurate seek. Earlier experiment with
        // `.positiveInfinity` tolerances to skip the IDR-to-target
        // decode pre-roll caused AVPlayer to land on apparently-
        // arbitrary sync samples far from the requested time — the
        // user's TestFlight session showed the image "hanging" on
        // wrong-position content during forward scrubs. AVPlayer's
        // "most efficient seek" interpretation of unbounded tolerance
        // appears to be undefined for HLS-fMP4 served over loopback,
        // matching the long-standing openradar 44904505 bug report.
        // Keep tolerances at zero until we have a different lever
        // (predictive engine prefetch on scrub commit) that doesn't
        // depend on tolerance semantics.
        avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ value: Float) {
        avPlayer.rate = value
    }

    // MARK: - Internal

    private func unloadCurrentItem() {
        if let to = timeObserver {
            avPlayer.removeTimeObserver(to)
            timeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        for obs in notificationObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        notificationObservers.removeAll()
        accessLogCount = 0
        avPlayer.replaceCurrentItem(with: nil)
        playerItem = nil
        isReady = false
        currentTime = 0
        duration = 0
        rate = 0
    }

    /// Log the asset's URL plus every track's media type, codec
    /// FourCC, enabled flag, and playable flag. Called from both the
    /// `item.status == .failed` path and the per-key `asset.load`
    /// failure path so DrHurt's "AVPlayer stalls in waitingToPlay
    /// instead of failing" sessions still surface the codec FourCCs
    /// (item.status never going `.failed` was the reason d9b8aa5's
    /// dump didn't fire in DrHurt's P5 MKV log).
    private static func dumpAssetTracks(_ asset: AVAsset, sid: Int, reason: String) {
        if let urlAsset = asset as? AVURLAsset {
            LogTap.shared.note("[NativeAVPlayer] #\(sid) asset.url=\(urlAsset.url.absoluteString) (\(reason))")
        }
        let tracks = asset.tracks
        if tracks.isEmpty {
            LogTap.shared.note("[NativeAVPlayer] #\(sid) asset.tracks empty (\(reason))")
            return
        }
        for track in tracks {
            let fourcc: String
            if let fmt = track.formatDescriptions.first {
                let cm = fmt as! CMFormatDescription
                fourcc = fourccString(CMFormatDescriptionGetMediaSubType(cm))
            } else {
                fourcc = "?"
            }
            LogTap.shared.note("[NativeAVPlayer] #\(sid) asset.track type=\(track.mediaType.rawValue) codec='\(fourcc)' enabled=\(track.isEnabled) playable=\(track.isPlayable) (\(reason))")
        }
    }

    /// Render a 4-byte CoreMedia FourCC subtype (e.g. 'hvc1', 'hev1',
    /// 'dvh1', 'avc1', 'mp4a') as a printable ASCII string. Used in
    /// failure-path diagnostics to surface the exact sample-entry
    /// codec tag AVPlayer saw, which lets us tell whether the source
    /// was hev1 / dvhe (DrHurt's known-rejected forms from
    /// AetherEngine#2) versus hvc1 / dvh1 (the accepted forms).
    private static func fourccString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        let chars = bytes.map { (b: UInt8) -> Character in
            (b >= 0x20 && b < 0x7f) ? Character(UnicodeScalar(b)) : "."
        }
        return String(chars)
    }
}
