import Testing
import Foundation
@testable import Sodalite

/// A second Next while the next track's PlaybackInfo is still in flight used to report a stop for
/// that track carrying the previous track's source, session and playhead, which can mark a track
/// played that was never heard. Audit 2026-09-25 MUSIC-SHELL-1.
@MainActor
struct MusicTrackSwitchReportTests {

    private func track(_ id: String) throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Audio"}"#.utf8)
        )
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aTrackThatNeverLoadedReportsNoStop() async throws {
        let service = RecordingPlaybackService()
        service.hangingItemIDs = ["B"]
        let coordinator = MusicPlaybackCoordinator(
            engine: DependencyContainer.playerEngine,
            playbackService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userIDProvider: { "user" }
        )
        coordinator.play(queue: [try track("A"), try track("B"), try track("C")], startAt: 0)
        await waitFor { service.playbackInfoRequests.contains("A") }
        // A's PlaybackInfo answered, so A has a session to close.
        try? await Task.sleep(for: .milliseconds(50))

        coordinator.next()
        await waitFor { service.playbackInfoRequests.contains("B") && !service.stoppedReports.isEmpty }
        coordinator.next()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(service.stoppedReports.map(\.itemId) == ["A"])
        #expect(service.stoppedReports.first?.mediaSourceId == "src-A")
        coordinator.stop()
    }
}
