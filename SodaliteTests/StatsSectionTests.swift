import Testing
@testable import Sodalite

/// The panel and the Up/Down cursor used to compute "which sections exist" separately, in two files, from
/// two different sources. They had drifted: the cursor asked `item.mediaSources` while the panel asked the
/// resolved source, so on any item whose payload lacked one the cursor stopped at an anchor nobody had
/// drawn and scrollTo silently did nothing (the "up doesn't work" shape). One function now answers both.
struct StatsSectionTests {

    @Test("the two unconditional sections are always there")
    func alwaysOnSections() {
        let sections = StatsSection.available(
            hasVideo: false, hasAudio: false, hasSubtitle: false,
            hasSourceDetail: false, showEngineDiagnostics: false)
        #expect(sections == [StatsSection.live, StatsSection.playback])
    }

    @Test("each optional section is gated on its own fact")
    func independentGates() {
        #expect(StatsSection.available(hasVideo: true, hasAudio: false, hasSubtitle: false,
                                       hasSourceDetail: false, showEngineDiagnostics: false)
                .contains(StatsSection.video))
        #expect(StatsSection.available(hasVideo: false, hasAudio: true, hasSubtitle: false,
                                       hasSourceDetail: false, showEngineDiagnostics: false)
                .contains(StatsSection.audio))
        #expect(StatsSection.available(hasVideo: false, hasAudio: false, hasSubtitle: true,
                                       hasSourceDetail: false, showEngineDiagnostics: false)
                .contains(StatsSection.subtitle))
        #expect(StatsSection.available(hasVideo: false, hasAudio: false, hasSubtitle: false,
                                       hasSourceDetail: true, showEngineDiagnostics: false)
                .contains(StatsSection.source))
    }

    @Test("the three diagnostic sections arrive and leave together")
    func diagnosticsAreOneUnit() {
        let on = StatsSection.available(hasVideo: false, hasAudio: false, hasSubtitle: false,
                                        hasSourceDetail: false, showEngineDiagnostics: true)
        #expect(on.isSuperset(of: [StatsSection.engine, StatsSection.buffer, StatsSection.network]))
        let off = StatsSection.available(hasVideo: false, hasAudio: false, hasSubtitle: false,
                                         hasSourceDetail: false, showEngineDiagnostics: false)
        #expect(off.isDisjoint(with: [StatsSection.engine, StatsSection.buffer, StatsSection.network]))
    }

    /// Every index the function can return has to have an anchor, or the cursor scrolls to an id that is
    /// not in the view and stops moving.
    @Test("every reachable index names an anchor")
    func everyIndexIsAnchored() {
        let all = StatsSection.available(hasVideo: true, hasAudio: true, hasSubtitle: true,
                                         hasSourceDetail: true, showEngineDiagnostics: true)
        #expect(all.count == PlayerViewModel.statsSectionAnchors.count)
        for index in all {
            #expect(PlayerViewModel.statsSectionAnchors.indices.contains(index))
        }
    }

    /// File and channel share index 5. Two anchors for what is one position would put a gap in the cursor's
    /// walk on whichever session type did not render its half.
    @Test("file and channel are the same position")
    func sourceSectionIsOnePosition() {
        #expect(PlayerViewModel.statsSectionAnchors[StatsSection.source] == "stats.section.file")
    }
}
