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

    // AE#207: Int.max is the engine's contract for "buffer the entire source"; it clamps to 2700 and
    // bounds the prefetch by the session disk budget instead of the segment count.
    @Test func unlimitedRequestsTheWholeSource() {
        #expect(PlaybackPreferences.NetworkBufferDepth.unlimited.forwardBufferSegments == Int.max)
    }

    // Contract against AetherEngine AE#102/AE#207: forwardWindow clamp is 4...2700, plus Int.max as
    // the explicit whole-source request.
    @Test func allNonNilStagesWithinEngineClamp() {
        for depth in PlaybackPreferences.NetworkBufferDepth.allCases {
            if let seg = depth.forwardBufferSegments {
                #expect(seg >= 4)
                #expect(seg <= 2700 || seg == Int.max)
            }
        }
    }

    // The picker reads allCases, so the order is the user-visible ladder.
    @Test func stagesAreOrderedByDepth() {
        #expect(PlaybackPreferences.NetworkBufferDepth.allCases
            == [.system, .oneMinute, .fiveMinutes, .maximum, .unlimited])
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

    @Test func persistsUnlimitedAcrossInstances() {
        let suite = UserDefaults(suiteName: "NetworkBufferDepthTests.unlimited")!
        suite.removePersistentDomain(forName: "NetworkBufferDepthTests.unlimited")
        let a = PlaybackPreferences(store: suite)
        a.networkBufferDepth = .unlimited
        let b = PlaybackPreferences(store: suite)
        #expect(b.networkBufferDepth == .unlimited)
    }
}
