import Foundation
import Combine

/// Ring buffer of recent diagnostic log lines, surfaced into the
/// player overlay so a TestFlight beta tester can screenshot what
/// the engine reported during playback when they have no Mac to
/// pair with Console.app.
///
/// Lines arrive via two paths:
///   - `AetherEngine.EngineLog.handler` (preferred) for engine prints
///     that go through the explicit broadcaster.
///   - Direct `LogTap.shared.note(_:)` calls from host code (e.g.
///     PlayerViewModel) for things the engine doesn't see.
///
/// We deliberately do **not** redirect `stdout` via `dup2` any more,
/// the previous approach was unreliable on tvOS Release builds where
/// stdout is silently null-redirected when no debugger is attached.
/// The type is MainActor-isolated (project default), which is what
/// the `lines` publisher wants. `note(_:)`/`clear()` are explicitly
/// `nonisolated`: they are wired into `AetherEngine.EngineLog.handler`,
/// which the engine invokes from its own threads, and previously the
/// documented "safe to call from any thread" contract only held by
/// accident (the implicitly-isolated body happened not to touch state
/// outside the main-queue hop). The explicit annotation makes the
/// compiler enforce it.
final class LogTap: ObservableObject {

    nonisolated static let shared = LogTap()

    /// Whether the diagnostic overlay should be mounted at all.
    /// Always on under the debugger (DEBUG), on for sandbox-receipt
    /// builds (TestFlight), off for App Store builds so end users
    /// never see a developer overlay.
    nonisolated static let isDiagnosticBuild: Bool = {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }()

    @Published private(set) var lines: [String] = []

    /// Capacity of the in-memory ring buffer the overlay renders from.
    /// 300 lines is enough to hold a full HLS-wrapper session start
    /// (engine init.mp4 hex dump + box summary + master.m3u8 body +
    /// media.m3u8 head + per-request response logs) plus the eventual
    /// AVPlayer failure landing, without losing the early structural
    /// diagnostics by the time the player gives up. The previous 80
    /// rolled the `[FMP4VideoMuxer] init.mp4 …` summary off the top
    /// before the failure landed, defeating its purpose.
    private let maxLines = 300

    private nonisolated init() {}

    /// Append one line to the overlay. Safe to call from any thread.
    /// Long lines are truncated when rendered in the overlay (the
    /// view applies `lineLimit(1)` + tail truncation).
    nonisolated func note(_ line: String) {
        // Mirror to the console on diagnostic builds so host-side notes
        // show up in an Xcode/Console capture alongside the engine prints,
        // not only in the in-app overlay.
        if Self.isDiagnosticBuild {
            print(line)
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
