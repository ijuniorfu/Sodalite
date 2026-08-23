import Foundation
import Testing
@testable import Sodalite

/// Sodalite#70: every tuner release came back 404 because the request went to `/LiveTv/LiveStreams/Close`.
/// Jellyfin serves that action from MediaInfoController, whose class attribute is `[Route("")]`, so the
/// route is `/LiveStreams/Close` and has no LiveTv prefix. A close that 404s is a close that was never
/// sent, and nothing else ever releases a live stream: MediaSourceManager drops one only when the
/// consumer count reaches zero or the server shuts down.
@Suite("Live stream close route")
struct LiveStreamCloseRouteTests {

    @Test("CloseLiveStream posts to the route Jellyfin actually serves")
    func closeLiveStreamRoute() {
        let endpoint = JellyfinEndpoint.closeLiveStream(liveStreamID: "abc123")
        #expect(endpoint.path == "/LiveStreams/Close")
        #expect(endpoint.method == .post)
        #expect(endpoint.queryItems?.contains(URLQueryItem(name: "LiveStreamId", value: "abc123")) == true)
    }

    @Test("the LiveTv prefix that made it 404 is not back")
    func noLiveTvPrefix() {
        #expect(!JellyfinEndpoint.closeLiveStream(liveStreamID: "abc123").path.hasPrefix("/LiveTv"))
    }
}
