import Foundation
import Combine
import AetherEngine
import SwiftAssRenderer

/// Drives swift-ass-renderer from AetherEngine's data surface for
/// styled ASS/SSA subtitle tracks (AetherEngine#30 host contract):
///
///   raw paced event cues (`preserveASSMarkup`) + `TrackInfo.assHeader`
///   -> `ASSScriptBuilder` -> batched `reloadTrack(content:)`
///   `engine.clock.$sourceTime` -> `setTimeOffset`
///   `engine.fontAttachments` -> font directory -> `FontConfig`
///
/// One instance per session, owned by `PlayerViewModel`; inactive until an ASS/SSA track selected.
@MainActor
final class ASSRenderCoordinator {

    /// Non-nil exactly while an ASS track is active AND the renderer initialized; else the
    /// overlay falls back to the text path.
    private(set) var renderer: AssSubtitlesRenderer?

    /// Fires immediately BEFORE every `reloadTrack` so the overlay can suppress the renderer's
    /// transient re-parse nil deterministically (a pure time-based window loses the race when
    /// re-parse + font matching runs long and the sub blinks mid-line).
    let reloadSignal = PassthroughSubject<Void, Never>()

    private let player: AetherEngine
    private var builder: ASSScriptBuilder?
    private var cancellables = Set<AnyCancellable>()
    private var lastReloadAt = Date.distantPast
    private var pendingEvents = false
    /// Earliest start among events added since the last reload; drives the imminent-flush bypass.
    private var earliestPendingStart = Double.infinity
    /// Last clock-sink offset (source-PTS seconds), compared against `earliestPendingStart`.
    private var lastOffset: Double = 0
    /// Batch window before reparsing the whole script. Per-cue reload (1-2/s) is pointless churn;
    /// in steady-state streaming the side demuxer runs ~90 s ahead so new events are far off.
    private let reloadInterval: TimeInterval = 5
    /// Imminent-flush bypass: after a seek/mid-dialogue activation the catch-up burst delivers
    /// events within seconds of the playhead; holding them the full window drops a running
    /// dialogue's continuation lines (field repro: subs "ending too early" right after scrubs).
    /// A pending event starting inside this lead flushes immediately.
    private let imminentLeadSeconds: Double = 10
    /// Spacing even for imminent flushes so the post-seek catch-up burst (~1-2 s) coalesces into
    /// a few reloads instead of one libass parse per cue.
    private let minImminentSpacing: TimeInterval = 0.25

    init(player: AetherEngine) {
        self.player = player
    }

    /// Fired when the renderer becomes available asynchronously (first activation with unwritten
    /// fonts) or is torn down; PlayerViewModel mirrors it onto its observable surface.
    var onRendererChanged: ((AssSubtitlesRenderer?) -> Void)?
    /// Guards async font-write completion against a deactivate/re-activate during the writes.
    private var activationGeneration = 0

    /// Activate for the selected embedded track (`header` = track's `assHeader`). Bails (renderer
    /// stays nil, caller keeps the text path) when the header is missing or setup fails.
    /// Fonts are written off-main (anime MKVs embed dozens of 5-20 MB CJK faces); when all files
    /// already exist the renderer installs synchronously so `activate(...); renderer` still works.
    func activate(header: String?, itemID: String) {
        deactivate()
        guard let header, !header.isEmpty else { return }
        activationGeneration += 1
        let generation = activationGeneration
        let fontsDir = Self.fontsDirectory(itemID: itemID)
        let fonts = player.fontAttachments
        if Self.allFontsPresent(fonts, in: fontsDir) {
            installRenderer(fontsDir: fontsDir)
        } else {
            Task.detached(priority: .userInitiated) { [weak self] in
                Self.writeFontAttachments(fonts, to: fontsDir)
                await MainActor.run {
                    guard let self, self.activationGeneration == generation else { return }
                    self.installRenderer(fontsDir: fontsDir)
                }
            }
        }
        let builder = ASSScriptBuilder(header: header)
        self.builder = builder

        // Cue sink: accumulate raw event lines, reload batched. Post-seek re-emits (cue array
        // resets) are absorbed by the builder's ReadOrder dedupe.
        player.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in self?.consume(cues: cues) }
            .store(in: &cancellables)

        // Clock sink: cue times and sourceTime share the source-PTS coordinate (no conversion).
        // Doubles as trailing-batch flush, since the cue sink only runs on cue-array emissions
        // and a batch landing in the window with no later emission (EOF tail) would never flush.
        player.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                guard let self else { return }
                self.lastOffset = t
                self.renderer?.setTimeOffset(t)
                self.flushPendingEventsIfDue()
            }
            .store(in: &cancellables)
    }

    func deactivate() {
        activationGeneration += 1
        cancellables.removeAll()
        renderer?.freeTrack()
        renderer = nil
        builder = nil
        pendingEvents = false
        earliestPendingStart = .infinity
        lastReloadAt = .distantPast
    }

    private func installRenderer(fontsDir: URL) {
        let config = FontConfig(fontsPath: fontsDir, fontProvider: .coreText)
        let renderer = AssSubtitlesRenderer(fontConfig: config)
        self.renderer = renderer
        onRendererChanged?(renderer)
        // Surface events that arrived in the builder while fonts were being written.
        flushPendingEventsIfDue()
    }

    private func consume(cues: [SubtitleCue]) {
        guard let builder else { return }
        var addedAny = false
        for cue in cues {
            guard case .text(let raw) = cue.body else { continue }
            if builder.add(rawEventText: raw, start: cue.startTime, end: cue.endTime) {
                addedAny = true
                earliestPendingStart = min(earliestPendingStart, cue.startTime)
            }
        }
        if addedAny { pendingEvents = true }
        flushPendingEventsIfDue()
    }

    /// Reload the track when events are waiting and either the batch window elapsed or a pending
    /// event is imminent (within `imminentLeadSeconds`). Called from the cue sink and clock sink.
    /// `lastReloadAt` starts `.distantPast` so the first batch always passes the interval check.
    private func flushPendingEventsIfDue() {
        guard pendingEvents, let builder, let renderer else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastReloadAt)
        let imminent = earliestPendingStart <= lastOffset + imminentLeadSeconds
        let due = imminent ? elapsed >= minImminentSpacing : elapsed >= reloadInterval
        guard due else { return }
        lastReloadAt = now
        pendingEvents = false
        earliestPendingStart = .infinity
        reloadSignal.send()
        renderer.reloadTrack(content: builder.script())
    }

    // MARK: - Fonts

    private static func fontsDirectory(itemID: String) -> URL {
        // lastPathComponent so a hostile server itemID can't escape the cache dir; it passes
        // ".." through (resolves one level up when appended) so treat that like empty too.
        let safeID = (itemID as NSString).lastPathComponent
        let dirName = (safeID.isEmpty || safeID == "..") ? "item" : safeID
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ass-fonts", isDirectory: true)
            .appendingPathComponent(dirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private nonisolated static func allFontsPresent(_ fonts: [FontAttachment], in dir: URL) -> Bool {
        fonts.allSatisfy { font in
            let safeName = (font.filename as NSString).lastPathComponent
            guard !safeName.isEmpty else { return true }
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent(safeName).path)
        }
    }

    private nonisolated static func writeFontAttachments(_ fonts: [FontAttachment], to dir: URL) {
        for font in fonts {
            // lastPathComponent so a hostile container filename can't escape the cache dir.
            let safeName = (font.filename as NSString).lastPathComponent
            guard !safeName.isEmpty else { continue }
            let url = dir.appendingPathComponent(safeName)
            if !FileManager.default.fileExists(atPath: url.path) {
                // Atomic so a crash mid-write can't leave a truncated font the exists-check
                // above would then treat as complete forever.
                try? font.data.write(to: url, options: .atomic)
            }
        }
    }
}
