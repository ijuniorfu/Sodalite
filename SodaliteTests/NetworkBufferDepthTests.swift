import Testing
import Foundation
@testable import Sodalite

@MainActor
struct NetworkBufferDepthTests {

    @Test func systemMapsToEngineDefault() {
        #expect(PlaybackPreferences.NetworkBufferDepth.system.forwardBufferSegments == nil)
    }

    @Test func stagesMapToSegmentCounts() {
        #expect(PlaybackPreferences.NetworkBufferDepth.oneMinute.forwardBufferSegments == 15)
        #expect(PlaybackPreferences.NetworkBufferDepth.fiveMinutes.forwardBufferSegments == 75)
        #expect(PlaybackPreferences.NetworkBufferDepth.maximum.forwardBufferSegments == 150)
    }

    // Contract against AetherEngine AE#102: forwardWindow clamp is 4...150.
    @Test func allNonNilStagesWithinEngineClamp() {
        for depth in PlaybackPreferences.NetworkBufferDepth.allCases {
            if let seg = depth.forwardBufferSegments {
                #expect(seg >= 4 && seg <= 150)
            }
        }
    }

    @Test func titleKeyFollowsConvention() {
        #expect(PlaybackPreferences.NetworkBufferDepth.oneMinute.titleKey == "settings.playback.buffer.oneMinute")
    }

    @Test func defaultsToSystem() {
        let suite = UserDefaults(suiteName: "NetworkBufferDepthTests.default")!
        suite.removePersistentDomain(forName: "NetworkBufferDepthTests.default")
        let prefs = PlaybackPreferences(store: suite)
        #expect(prefs.networkBufferDepth == .system)
    }

    @Test func persistsAcrossInstances() {
        let suite = UserDefaults(suiteName: "NetworkBufferDepthTests.persist")!
        suite.removePersistentDomain(forName: "NetworkBufferDepthTests.persist")
        let a = PlaybackPreferences(store: suite)
        a.networkBufferDepth = .maximum
        let b = PlaybackPreferences(store: suite)
        #expect(b.networkBufferDepth == .maximum)
    }
}
