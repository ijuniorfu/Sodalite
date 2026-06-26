import Testing
@testable import Sodalite

/// #68: Sodalite caps the engine's open-time routing-probe budget for remote
/// direct-play / direct-stream sources (original container, sparse PGS tail),
/// but never for transcode (clean HLS, no sparse-track tail).
struct ProbeBudgetTests {

    @Test("direct play caps the routing probe budget")
    func directPlayCapsBudget() {
        let b = PlayerViewModel.remoteDirectPlayProbeBudget(method: .directPlay)
        #expect(b.probesize != nil)
        #expect(b.maxAnalyzeDuration != nil)
        // Must stay well under the engine default (50 MB / 60 s) to be a win,
        // and above audio's early-resolve needs so no audio track is lost.
        #expect(b.probesize! < 50 * 1024 * 1024)
        #expect(b.probesize! >= 8 * 1024 * 1024)
        #expect(b.maxAnalyzeDuration! < 60 * 1_000_000)
    }

    @Test("direct stream caps the routing probe budget (same original container)")
    func directStreamCapsBudget() {
        let b = PlayerViewModel.remoteDirectPlayProbeBudget(method: .directStream)
        #expect(b.probesize != nil)
        #expect(b.maxAnalyzeDuration != nil)
    }

    @Test("transcode keeps the engine default (no cap)")
    func transcodeKeepsDefault() {
        let b = PlayerViewModel.remoteDirectPlayProbeBudget(method: .transcode)
        #expect(b.probesize == nil)
        #expect(b.maxAnalyzeDuration == nil)
    }
}
