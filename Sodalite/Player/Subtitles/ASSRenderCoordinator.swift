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
/// One instance per playback session, owned by `PlayerViewModel`.
/// Inactive (nil renderer) until an ASS/SSA track is selected.
@MainActor
final class ASSRenderCoordinator {

    /// The renderer the overlay's `AssSubtitlesView` binds to.
    /// Non-nil exactly while an ASS track is active AND the renderer
    /// initialized; the overlay falls back to the text path otherwise.
    private(set) var renderer: AssSubtitlesRenderer?

    private let player: AetherEngine
    private var builder: ASSScriptBuilder?
    private var cancellables = Set<AnyCancellable>()
    private var lastReloadAt = Date.distantPast
    private var pendingEvents = false
    /// Batch window: collect newly arrived events for up to this long
    /// before reparsing the whole script. libass parses a full movie
    /// script in milliseconds, but reloading per cue (1-2/s) is
    /// pointless churn.
    private let reloadInterval: TimeInterval = 5

    init(player: AetherEngine) {
        self.player = player
    }

    /// Activate for the selected embedded track. `header` is the
    /// track's `assHeader`; bails (renderer stays nil) when the header
    /// is missing or renderer setup fails, in which case the caller
    /// keeps the plain-text overlay path.
    func activate(header: String?, itemID: String) {
        deactivate()
        guard let header, !header.isEmpty else { return }
        let fontsDir = Self.fontsDirectory(itemID: itemID)
        Self.writeFontAttachments(player.fontAttachments, to: fontsDir)
        let config = FontConfig(fontsPath: fontsDir, fontProvider: .coreText)
        let renderer = AssSubtitlesRenderer(fontConfig: config)
        self.renderer = renderer
        let builder = ASSScriptBuilder(header: header)
        self.builder = builder

        // Cue sink: accumulate raw event lines, reload batched. The
        // engine re-emits cues after seeks (cue array resets), which
        // the builder's ReadOrder dedupe absorbs.
        player.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in self?.consume(cues: cues) }
            .store(in: &cancellables)

        // Clock sink: cue times and sourceTime share the source-PTS
        // coordinate, no conversion.
        player.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in self?.renderer?.setTimeOffset(t) }
            .store(in: &cancellables)
    }

    func deactivate() {
        cancellables.removeAll()
        renderer?.freeTrack()
        renderer = nil
        builder = nil
        pendingEvents = false
        lastReloadAt = .distantPast
    }

    private func consume(cues: [SubtitleCue]) {
        guard let builder else { return }
        var addedAny = false
        for cue in cues {
            guard case .text(let raw) = cue.body else { continue }
            if builder.add(rawEventText: raw, start: cue.startTime, end: cue.endTime) {
                addedAny = true
            }
        }
        if addedAny { pendingEvents = true }
        guard pendingEvents else { return }
        let now = Date()
        if now.timeIntervalSince(lastReloadAt) >= reloadInterval || lastReloadAt == .distantPast {
            lastReloadAt = now
            pendingEvents = false
            renderer?.reloadTrack(content: builder.script())
        }
    }

    // MARK: - Fonts

    private static func fontsDirectory(itemID: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ass-fonts", isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func writeFontAttachments(_ fonts: [FontAttachment], to dir: URL) {
        for font in fonts {
            // Attachment filenames come from the container; keep only
            // the last path component so a hostile name can't escape
            // the cache directory.
            let safeName = (font.filename as NSString).lastPathComponent
            guard !safeName.isEmpty else { continue }
            let url = dir.appendingPathComponent(safeName)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? font.data.write(to: url)
            }
        }
    }
}
