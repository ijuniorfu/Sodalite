import Testing
import AetherEngine
@testable import Sodalite

/// AetherEngine #127 host adoption: the engine's paused-background grace window (and PiP keepalive)
/// can hold the pipeline alive across a real backgrounding. Only a torn-down session (backend .none)
/// pays the foreground reload; reloading a live pipeline would throw away exactly the rebuild the
/// grace window avoided.
@Suite("Foreground return reload gate")
struct ForegroundReloadGateTests {

    @Test("playing session never reloads (PiP / background audio keepalive)")
    func playingNeverReloads() {
        #expect(PlayerHostController.foregroundReturnNeedsReload(state: .playing, backend: .native) == false)
    }

    @Test("paused session with a live pipeline skips the reload (grace window survived the switch)")
    func pausedLivePipelineSkipsReload() {
        #expect(PlayerHostController.foregroundReturnNeedsReload(state: .paused, backend: .native) == false)
        #expect(PlayerHostController.foregroundReturnNeedsReload(state: .paused, backend: .software) == false)
    }

    @Test("paused session after the background teardown reloads (backend dropped to .none)")
    func pausedTornDownReloads() {
        #expect(PlayerHostController.foregroundReturnNeedsReload(state: .paused, backend: .none) == true)
    }

    @Test("idle torn-down session reloads")
    func idleTornDownReloads() {
        #expect(PlayerHostController.foregroundReturnNeedsReload(state: .idle, backend: .none) == true)
    }
}
