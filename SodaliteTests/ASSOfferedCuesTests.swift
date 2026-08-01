import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// AetherEngine#271: `$subtitleCues` carries the whole cumulative cue array on every publication,
/// and a snapshot cannot say which of its elements are new. The ASS coordinator's sink therefore
/// re-walked every retained cue each time and handed all of them to `ASSScriptBuilder.add`, which
/// per cue splits the raw event, splits its nine fields, materializes a `start|end|line` key and
/// hashes it. On a typeset track (thousands of retained cues) that is thousands of string builds
/// per publication to learn that nothing changed.
///
/// `OfferedCues` is the filter in front of that walk. It is keyed on the engine's session-monotonic
/// cue id plus `endTime`, so a cue closed in place (AetherEngine#107 teletext page semantics) is
/// still offered again, exactly as before the filter existed.
@MainActor
struct ASSOfferedCuesTests {

    private func cue(id: Int, start: Double = 100, end: Double = 105,
                     _ text: String = "Dialogue") -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text(text))
    }

    /// Mirrors the sink's loop: hand the publication to the filter, keep what it lets through.
    private func taken(_ cues: [SubtitleCue],
                       _ offered: inout ASSRenderCoordinator.OfferedCues) -> [Int] {
        var out: [Int] = []
        for cue in cues where offered.take(cue) { out.append(cue.id) }
        return out
    }

    @Test("a cue is taken once and skipped on every later publication of the same array")
    func cumulativeRepublicationIsFree() {
        var offered = ASSRenderCoordinator.OfferedCues()
        let snapshot = (0..<5).map { cue(id: $0, start: Double($0)) }

        #expect(taken(snapshot, &offered) == [0, 1, 2, 3, 4])
        // Same array republished: the engine ticks again, nothing new decoded.
        #expect(taken(snapshot, &offered).isEmpty)
        #expect(taken(snapshot, &offered).isEmpty)
    }

    @Test("a cumulative array that grew hands over only the added cues")
    func onlyNewCuesAreTaken() {
        var offered = ASSRenderCoordinator.OfferedCues()
        let first = (0..<3).map { cue(id: $0, start: Double($0)) }
        _ = taken(first, &offered)

        let grown = first + (3..<6).map { cue(id: $0, start: Double($0)) }
        #expect(taken(grown, &offered) == [3, 4, 5])
    }

    /// A retained cue closed by its successor keeps its id and changes only `endTime`. The builder
    /// dedupes on content including the end, so it has always treated that as a distinct event;
    /// the filter must not swallow it.
    @Test("a cue closed in place is offered again")
    func trimmedCueIsOfferedAgain() {
        var offered = ASSRenderCoordinator.OfferedCues()
        let openEnded = [cue(id: 7, start: 100, end: 999)]
        let closed = [cue(id: 7, start: 100, end: 104)]

        #expect(taken(openEnded, &offered) == [7])
        #expect(taken(openEnded, &offered).isEmpty)
        #expect(taken(closed, &offered) == [7])
    }

    /// A seek rebuilds the engine's overlay decoder, whose backscan re-decodes cues the retained
    /// store still holds. Those keep their ids (the store dedupes them), so they cost nothing here.
    /// Cues that had been pruned come back with fresh ids and are handed over again, where the
    /// builder's own content dedupe decides.
    @Test("a post-seek re-emission costs nothing for cues that kept their ids")
    func postSeekReemissionIsFree() {
        var offered = ASSRenderCoordinator.OfferedCues()
        let retained = (10..<14).map { cue(id: $0, start: Double($0)) }
        _ = taken(retained, &offered)

        let afterSeek = retained + [cue(id: 40, start: 9.5, "re-decoded, pruned earlier")]
        #expect(taken(afterSeek, &offered) == [40])
    }

    @Test("reset re-offers everything: a new track means a new builder")
    func resetReoffersEverything() {
        var offered = ASSRenderCoordinator.OfferedCues()
        let snapshot = (0..<4).map { cue(id: $0, start: Double($0)) }
        _ = taken(snapshot, &offered)
        #expect(taken(snapshot, &offered).isEmpty)

        offered.reset()
        #expect(taken(snapshot, &offered) == [0, 1, 2, 3])
    }
}
