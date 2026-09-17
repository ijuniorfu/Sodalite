import Foundation
import Testing
@testable import Sodalite

@Suite("Device values split from profile values", .serialized)
@MainActor
struct DevicePreferencesSplitTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "deviceSplit.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func twoProfilesDoNotShareTheirOwnValues() {
        let defaults = scratch("isolation")
        let device = DevicePreferences(store: defaults)
        let alice = PlaybackPreferences(store: defaults, scope: "s:alice", device: device)
        let bob = PlaybackPreferences(store: defaults, scope: "s:bob", device: device)

        alice.subtitleFontSize = .xlarge

        #expect(bob.subtitleFontSize == .medium)
        #expect(PlaybackPreferences(store: defaults, scope: "s:alice", device: device).subtitleFontSize == .xlarge)
        #expect(defaults.string(forKey: "playback.subtitleFontSize") == nil)
    }

    @Test func deviceValuesAreSharedAndKeepTheirOldKeys() {
        let defaults = scratch("shared")
        let device = DevicePreferences(store: defaults)
        let alice = PlaybackPreferences(store: defaults, scope: "s:alice", device: device)
        let bob = PlaybackPreferences(store: defaults, scope: "s:bob", device: device)
        let aliceLook = AppearancePreferences(store: defaults, scope: "s:alice", device: device)

        alice.networkBufferDepth = .maximum
        aliceLook.showTopShelfRow = false

        #expect(bob.networkBufferDepth == .maximum)
        #expect(defaults.string(forKey: "playback.networkBufferDepth") == "maximum")
        #expect(defaults.object(forKey: "appearance.showTopShelfRow") as? Bool == false)
        #expect(defaults.object(forKey: "s:alice/playback.networkBufferDepth") == nil)
    }

    @Test func anUpgradedDeviceReadsItsDeviceValuesFromTheOldKeys() {
        let defaults = scratch("upgrade")
        defaults.set("unlimited", forKey: "playback.networkBufferDepth")
        defaults.set(false, forKey: "playback.touchpadScrubbing")

        let device = DevicePreferences(store: defaults)

        #expect(device.networkBufferDepth == .unlimited)
        #expect(!device.touchpadScrubbing)
    }
}
