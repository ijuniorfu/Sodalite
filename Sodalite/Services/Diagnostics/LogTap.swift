import Foundation
import Combine
import StoreKit

/// Ring buffer of diagnostic log lines for the player overlay so a TestFlight tester with no Mac can screenshot engine output. Lines arrive via `AetherEngine.EngineLog.handler` (engine) and direct `note(_:)` (host). Does NOT redirect stdout via dup2: unreliable on tvOS Release (stdout null-redirected with no debugger). Type is MainActor-isolated for the `lines` publisher; `note(_:)`/`clear()` are explicitly `nonisolated` because the engine calls them off its own threads (the compiler now enforces what was previously safe only by accident).
final class LogTap: ObservableObject {

    nonisolated static let shared = LogTap()

    /// Mount the diagnostic overlay? On for DEBUG + sandbox (TestFlight), off for App Store. Sandbox detection mirrors `StoreKitService.isSupporter`: authoritative answer is async `AppTransaction` (receipt-URL deprecated tvOS 18) but this flag is read synchronously in `SodaliteApp.init`, so read a UserDefaults cache and let `refreshDiagnosticBuildFlag()` overwrite per launch (first TestFlight launch = off, every later launch = on).
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

    @Published private(set) var lines: [String] = []

    // 300: holds a full HLS-wrapper session start (init.mp4 dump + m3u8 bodies + per-request logs) through the eventual AVPlayer failure; the previous 80 rolled the init.mp4 summary off before the failure landed.
    private let maxLines = 300

    private nonisolated init() {}

    /// Append one line to the overlay. Safe to call from any thread.
    nonisolated func note(_ line: String) {
        // Mirror to console on diagnostic builds so host notes appear in an Xcode/Console capture alongside engine prints.
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
