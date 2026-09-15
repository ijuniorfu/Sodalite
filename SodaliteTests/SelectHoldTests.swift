import Testing
@testable import Sodalite

/// Sodalite#104 round 3: a Select press held past the hold threshold is still a press.
///
/// The hold recognizer exists to delete a highlighted external subtitle, and the short tap waits for
/// it to fail before it fires. So a click held for 0.35 s anywhere else did nothing: a confirming
/// press over a pending scrub produced no seek, no pause and no log line, which in a device capture
/// is indistinguishable from a press that never arrived.
@Suite("A held Select press (Sodalite#104 round 3)")
struct SelectHoldTests {

    private let rows = SubtitleMenuLayout.rows(streams: [], supportsSecondary: false, supportsSearch: false)
        + [.track(streamIndex: 3), .track(streamIndex: 7)]

    @Test func aHoldOverAnExternalSubtitleDeletesIt() {
        // rows: [.off, .track(3), .track(7)], and 7 is the external one
        #expect(PlayerHostController.selectHold(dropdown: .subtitle(highlighted: 2), rows: rows,
                                                externalStreamIndices: [7])
                == .deleteSubtitle(streamIndex: 7))
    }

    @Test func aHoldWithNoMenuOpenIsAClick() {
        #expect(PlayerHostController.selectHold(dropdown: .none, rows: rows, externalStreamIndices: [7])
                == .click)
    }

    @Test func aHoldOverAnEmbeddedTrackOrOffIsAClick() {
        #expect(PlayerHostController.selectHold(dropdown: .subtitle(highlighted: 1), rows: rows,
                                                externalStreamIndices: [7]) == .click)
        #expect(PlayerHostController.selectHold(dropdown: .subtitle(highlighted: 0), rows: rows,
                                                externalStreamIndices: [7]) == .click)
    }

    @Test func aHoldInAnotherMenuIsAClick() {
        #expect(PlayerHostController.selectHold(dropdown: .audio(highlighted: 2), rows: rows,
                                                externalStreamIndices: [7]) == .click)
    }

    @Test func aStaleHighlightPastTheRowsIsAClick() {
        #expect(PlayerHostController.selectHold(dropdown: .subtitle(highlighted: 9), rows: rows,
                                                externalStreamIndices: [7]) == .click)
    }
}
