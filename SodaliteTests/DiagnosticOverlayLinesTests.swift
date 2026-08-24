import Testing
@testable import Sodalite

/// The diagnostic HUD is the only place a TestFlight tester can read which route a live tune took, and
/// on Sodalite#70 it could not be read at all: the focus toggle defaults ON and its matcher list never
/// mentioned `[LiveDirect]`, so the line the reporter was asked to screenshot was filtered out of the
/// only view he had. The rolling window would have lost it anyway, because a route is decided before the
/// first frame and a slow tune emits far more than a window of engine chatter after it.
struct DiagnosticOverlayLinesTests {

    private static let routeLine = "[LiveDirect] route=tunerfile path=/LiveTv/LiveStreamFiles/da02/stream.ts"
    private static let retreatLine = "[LiveDirect] route=static reason=tunerfile_load_failed(noSource)"

    /// Engine chatter of the kind a live tune produces between the route decision and the first frame.
    private static func chatter(_ count: Int) -> [String] {
        (0..<count).map { "[AetherEngine] segment \($0) appended" }
    }

    @Test func theFocusedViewKeepsTheLiveRouteVocabulary() {
        let lines = [Self.routeLine, "[AudioBridge] EAC3", "[muxer] wrote 12 packets"]

        let focused = DiagnosticOverlayLines.rolling(from: lines, focused: true, limit: 50)

        #expect(focused.contains("[AudioBridge] EAC3"))
        #expect(!focused.contains("[muxer] wrote 12 packets"))
        // Pinned lines are drawn separately, so the route is absent HERE and present up there.
        #expect(DiagnosticOverlayLines.pinned(from: lines, limit: 4) == [Self.routeLine])
    }

    /// The failure that cost a reporter round: a decision taken before the picture, read after it.
    @Test func aRouteSurvivesAWindowOfChatterAfterIt() {
        let lines = [Self.routeLine] + Self.chatter(400)

        let pinned = DiagnosticOverlayLines.pinned(from: lines, limit: 4)
        let rolling = DiagnosticOverlayLines.rolling(from: lines, focused: false, limit: 50)

        #expect(pinned == [Self.routeLine])
        #expect(!rolling.contains(Self.routeLine))
    }

    /// A retreat is two lines, and the second one alone is a wrong answer: it names the route that ran,
    /// not the one that was tried and failed. Both have to stay up.
    @Test func aRetreatKeepsBothTheRouteTriedAndTheOneItFellBackTo() {
        let lines = Self.chatter(20) + [Self.routeLine] + Self.chatter(80) + [Self.retreatLine] + Self.chatter(200)

        let pinned = DiagnosticOverlayLines.pinned(from: lines, limit: 4)

        #expect(pinned == [Self.routeLine, Self.retreatLine])
    }

    /// Only the most recent few, so a session that retunes repeatedly does not push the picture off the
    /// top of the screen with its own history.
    @Test func onlyTheMostRecentDecisionsAreHeld() {
        let routes = (0..<10).map { "[LiveDirect] route=tunerfile attempt=\($0)" }

        let pinned = DiagnosticOverlayLines.pinned(from: routes, limit: 4)

        #expect(pinned == Array(routes.suffix(4)))
    }

    /// AE#407, the same gap one path over: VC-1 judder was reported from the software path, whose
    /// entire vocabulary was missing from the matcher list. The per-second frame ledger is the line
    /// that separates a starved decoder from a presentation problem, and a reporter asked for a
    /// screenshot of the HUD had no way to produce one.
    @Test func theFocusedViewKeepsTheSoftwarePathVocabulary() {
        let lines = [
            "[SWDecoder] Opened: 1920x1080, codec=vc1, threads=1, 8-bit",
            "[SWDiag] clk=12.01 dclk=1.00 enq=+24 layerDrop=0(+0) delay=0.00(+0.00) status=rendering",
            "[Renderer] dropped 250 frame(s) with no usable timestamp (unschedulable)",
            "[SWHost] first video frame enqueued: pixfmt=0x34323076 size=1920x1080 pts=0.042s",
            "[muxer] wrote 12 packets",
        ]

        let focused = DiagnosticOverlayLines.rolling(from: lines, focused: true, limit: 50)

        #expect(focused.count == 4)
        #expect(!focused.contains("[muxer] wrote 12 packets"))
    }

    @Test func theUnfocusedViewStillShowsEverythingElseInOrder() {
        let lines = Self.chatter(3)

        #expect(DiagnosticOverlayLines.rolling(from: lines, focused: false, limit: 50) == lines)
    }
}
