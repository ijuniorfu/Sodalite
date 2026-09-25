import AetherEngine
import Foundation
import Combine
import StoreKit

/// Ring buffer of diagnostic log lines for Settings > Diagnostic Log so a tester with no Mac can read and screenshot them. Every line is stored with a fixed-width UTC stamp already in front of it, so the screenshot, the iOS Copy output and the console mirror cannot disagree about when something happened. Lines arrive via `AetherEngine.EngineLog.handler` (engine) and direct `note(_:)` (host). Does NOT redirect stdout via dup2: unreliable on tvOS Release (stdout null-redirected with no debugger). Type is MainActor-isolated for the `lines` publisher; `note(_:)`/`clear()` are explicitly `nonisolated` because the engine calls them off its own threads (the compiler now enforces what was previously safe only by accident).
final class LogTap: ObservableObject {

    nonisolated static let shared = LogTap()

    /// Mirror every line to the console as well? On for DEBUG + sandbox (TestFlight), off for App Store. Engine lines reach the buffer on EVERY build (see SodaliteApp), so this no longer gates what Settings > Diagnostic Log can show. Sandbox detection mirrors `StoreKitService.isSupporter`: authoritative answer is async `AppTransaction` (receipt-URL deprecated tvOS 18) but this flag is read synchronously in `SodaliteApp.init`, so read a UserDefaults cache and let `refreshDiagnosticBuildFlag()` overwrite per launch (first TestFlight launch = off, every later launch = on).
    nonisolated static let isDiagnosticBuild: Bool = {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: sandboxBuildCacheKey)
        #endif
    }()

    private nonisolated static let sandboxBuildCacheKey = "logTap.cachedIsSandboxBuild"

    /// Re-derive the cached sandbox flag from StoreKit 2; effective next launch (isDiagnosticBuild is a per-launch snapshot). Leaves the cache untouched on unverified transaction (offline) so a transient failure doesn't lose a true flag.
    nonisolated static func refreshDiagnosticBuildFlag() async {
        guard case .verified(let transaction)? = try? await AppTransaction.shared else { return }
        UserDefaults.standard.set(
            transaction.environment == .sandbox,
            forKey: sandboxBuildCacheKey
        )
    }

    /// The build these lines came out of, as one line. The engine number is the one a reader cannot
    /// reconstruct afterwards, because SwiftPM pins a revision rather than a tag, and a log analysed
    /// without it gets the version supplied from an older thread (AetherPlayer#7). It is noted at
    /// launch and prepended to every way the log leaves the device, because the buffer is 300 lines
    /// and a long session rolls the noted copy off the top.
    nonisolated static var environmentLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Sodalite \(version) (\(build)) | AetherEngine \(AetherEngine.version)"
            + " | \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    @Published private(set) var lines: [String] = []

    // 300: holds a full HLS-wrapper session start (init.mp4 dump + m3u8 bodies + per-request logs) through the eventual AVPlayer failure; the previous 80 rolled the init.mp4 summary off before the failure landed.
    private let maxLines = 300

    private nonisolated init() {}

    /// Append one line to the buffer. Safe to call from any thread.
    ///
    /// The single door every line comes through, host and engine alike, which is why credential
    /// stripping and the UTC stamp both sit here and not at the call sites (see LogRedaction,
    /// LogTimestamp). The stamp is taken first, before any work on the line, so it dates the moment the
    /// line was emitted rather than the moment it reached the buffer: `note` hops to the main actor to
    /// append, and two threads that hop in the same instant can land in either order. Reading a stamp
    /// out of order is then a true statement about a race, where an append-time stamp would have hidden
    /// it. An engine line is dated just as honestly, because `EngineLog` calls its handler synchronously
    /// on the thread that emitted it.
    nonisolated func note(_ line: String) {
        let stamp = LogTimestamp.stamp()
        // Stamp AFTER redaction, so the redactor never scans the stamp and the offsets it reports (were
        // it ever to report any) stay offsets into the line its author wrote.
        let line = "\(stamp)  \(LogRedaction.redact(line))"
        // Mirror to console on diagnostic builds so host notes appear in an Xcode/Console capture alongside engine prints.
        if Self.isDiagnosticBuild {
            print(line)
        }
        if Self.fileSinkEnabled {
            appendToFile(line)
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lines.append(line)
                if self.lines.count > self.maxLines {
                    self.lines.removeFirst(self.lines.count - self.maxLines)
                }
            }
        }
    }

    /// A measurement that outlives the app.
    ///
    /// The buffer above is 300 lines in memory, wiped on every launch, which is the right shape for
    /// "what went wrong just now" and the wrong one for a test that runs for ten minutes or that ends
    /// with the app being terminated in the background. A twelve minute pause on a live channel is
    /// both: measured on a device, the session that was meant to produce the evidence came back with
    /// nothing in it but the next launch.
    ///
    /// AE#597: it used to be debug-only, which made the one class of bug that needs it the one class
    /// it could not be used on. A wake-from-sleep failure puts an hour between the cause and the
    /// symptom and ends with a reboot, so a TestFlight capture came back holding 300 lines of
    /// aftermath and nothing of the transition. It is now a switch anybody can turn on, off by
    /// default, and every line has already been through `LogRedaction` by the time it gets here.
    ///
    /// Capped so a long session cannot fill the container, as two halves: when the live file reaches
    /// `fileSegmentBytes` it becomes `sodalite-log.1.txt` (replacing the previous one) and a fresh file
    /// starts. A single capped file had to stop writing when full, which dropped the NEWEST lines, the
    /// ones next to the symptom; rotating drops the oldest instead. `Library/Caches` because tvOS forbids app
    /// writes to `Documents` and the failure there is a swallowed throw, which reads exactly like
    /// "the app produced no logs". Pull it with:
    ///
    ///     xcrun devicectl device copy from --device <uuid> \
    ///       --domain-type appDataContainer --domain-identifier de.superuser404.Sodalite \
    ///       --user mobile --source Library/Caches/sodalite-log.txt --destination pulled.txt
    private nonisolated static let fileQueue =
        DispatchQueue(label: "de.superuser404.sodalite.logfile")
    nonisolated static let fileCapBytes = 32 * 1024 * 1024
    nonisolated static let fileSegmentBytes = fileCapBytes / 2

    /// Read once per line on the emitting thread, so it is a cached flag rather than a defaults
    /// read: `note(_:)` runs several times a second on a live session. Written at launch and when
    /// the switch is flipped.
    nonisolated(unsafe) static var fileSinkEnabled = false
    nonisolated static let fileSinkDefaultsKey = "diagnostics.persistentLog"

    /// Owned here rather than by `DevicePreferences`, because the log is reachable from setup,
    /// before a server exists and before the dependency graph is built, and the switch has to work
    /// on exactly that screen.
    nonisolated static func setFileSinkEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: fileSinkDefaultsKey)
        fileSinkEnabled = enabled
        if enabled {
            startFileSink()
        } else {
            LogTap.shared.note("[LogTap] file sink off; the file on disk is left where it is")
        }
    }

    /// A factory reset: the sink stops and both files go. On the file queue, so a line already
    /// queued lands before the removal and none after it (appends never create the file).
    nonisolated static func discardPersistedLog() {
        fileSinkEnabled = false
        let urls = persistedLogURLs
        fileQueue.async {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    nonisolated static var fileSinkURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sodalite-log.txt")
    }

    nonisolated static var rotatedFileSinkURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sodalite-log.1.txt")
    }

    /// Oldest first, the order an export concatenates them in.
    nonisolated static var persistedLogURLs: [URL] {
        [rotatedFileSinkURL, fileSinkURL].compactMap { $0 }
    }

    /// One marker per launch, so a file with nothing in it after it says "no lines were emitted"
    /// rather than "the sink is broken".
    ///
    /// Arming **appends**, it does not start a fresh file. The sink exists for transitions the
    /// memory ring rolls out, and those repros span an hour of sleep plus a look at other apps
    /// afterwards, in which tvOS may evict the app: truncating here would make the relaunch that
    /// follows the thing that destroys the evidence. A full file rotates on the next line instead.
    nonisolated static func startFileSink() {
        guard let url = fileSinkURL else { return }
        fileQueue.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }
        LogTap.shared.note("[LogTap] file sink armed at \(url.path)")
    }

    nonisolated private func appendToFile(_ line: String) {
        guard let url = Self.fileSinkURL, let rotated = Self.rotatedFileSinkURL else { return }
        Self.fileQueue.async {
            Self.append(line, to: url, rotatingTo: rotated, segmentBytes: Self.fileSegmentBytes)
        }
    }

    /// Synchronous and static so the rotation can be tested against a small segment. Only ever called
    /// on `fileQueue`, which is what makes the check-then-rename below race free.
    ///
    /// The marker is written straight to the new file rather than through `note(_:)`, which would come
    /// back here on the queue this is already running on.
    nonisolated static func append(_ line: String, to url: URL, rotatingTo rotated: URL, segmentBytes: Int) {
        guard var handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        var text = line + "\n"
        let end = (try? handle.seekToEnd()) ?? 0
        if end >= UInt64(segmentBytes) {
            try? handle.close()
            let manager = FileManager.default
            try? manager.removeItem(at: rotated)
            guard (try? manager.moveItem(at: url, to: rotated)) != nil else { return }
            manager.createFile(atPath: url.path, contents: nil)
            guard let fresh = try? FileHandle(forWritingTo: url) else { return }
            handle = fresh
            text = "\(LogTimestamp.stamp())  [LogTap] file sink rotated, earlier lines are in "
                + "\(rotated.lastPathComponent)\n" + text
        }
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// Moves what the Top Shelf extension logged in its own process into the buffer (see `ShelfLog`).
    ///
    /// Those lines are already stamped and redacted, so they skip `note(_:)`: re-stamping would date
    /// them to the moment the app woke up rather than the moment the shelf ran. They are merged in by
    /// stamp, because they are usually older than what the app has logged since launch.
    nonisolated func importShelfLines() {
        #if os(tvOS)
        guard let file = ShelfLogFile.shared else { return }
        DispatchQueue.global(qos: .utility).async {
            let imported = file.drain()
            guard !imported.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let tap = LogTap.shared
                    tap.lines = LogTap.merged(tap.lines, imported, limit: tap.maxLines)
                }
            }
        }
        #endif
    }

    /// Both inputs in stamp order, output in stamp order and at most `limit` long, the oldest dropped.
    /// A tie keeps the buffer's own line first.
    nonisolated static func merged(_ existing: [String], _ imported: [String], limit: Int) -> [String] {
        var result: [String] = []
        result.reserveCapacity(existing.count + imported.count)
        var i = 0
        var j = 0
        while i < existing.count || j < imported.count {
            if j == imported.count
                || (i < existing.count
                    && existing[i].prefix(LogTimestamp.width) <= imported[j].prefix(LogTimestamp.width)) {
                result.append(existing[i])
                i += 1
            } else {
                result.append(imported[j])
                j += 1
            }
        }
        return Array(result.suffix(limit))
    }

    /// Wipe the buffer (e.g. between playback sessions so the next
    /// test starts with a clean slate).
    nonisolated func clear() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.lines.removeAll()
            }
        }
    }
}
