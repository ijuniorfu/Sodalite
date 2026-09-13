import Testing
@testable import Sodalite

/// Sodalite#140 follow-up. Which view presents the music player is the whole bug: under the sidebar
/// the router shares its hosting controller with the album cover, so its cover was refused and the
/// player only appeared after the viewer pressed back once.
@MainActor
struct NowPlayingPresentationTests {

    @Test("with nothing presented above it, the router is the presenter")
    func routerPresentsByDefault() {
        let presentation = NowPlayingPresentation()
        #expect(presentation.routerPresents)
        #expect(presentation.isPresented == false)

        presentation.present()
        #expect(presentation.isPresented)
        #expect(presentation.routerPresents)
    }

    @Test("a surface above the router takes the presentation over while it is on screen")
    func hostClaimsThePresentation() {
        let presentation = NowPlayingPresentation()
        let cover = NowPlayingPresentation.HostToken()

        presentation.pushHost(cover)
        #expect(presentation.routerPresents == false, "the router must stand down, its cover is refused")
        #expect(presentation.presents(cover))
    }

    @Test("of two stacked covers the innermost presents")
    func innermostHostWins() {
        let presentation = NowPlayingPresentation()
        let outer = NowPlayingPresentation.HostToken()
        let inner = NowPlayingPresentation.HostToken()

        presentation.pushHost(outer)
        presentation.pushHost(inner)

        #expect(presentation.presents(inner))
        #expect(presentation.presents(outer) == false)
    }

    @Test("a host that reappears does not overtake one that is still up")
    func reappearKeepsItsPlace() {
        let presentation = NowPlayingPresentation()
        let outer = NowPlayingPresentation.HostToken()
        let inner = NowPlayingPresentation.HostToken()
        presentation.pushHost(outer)
        presentation.pushHost(inner)

        // The order of appear/disappear across a presentation is not fixed, so the outer cover's
        // appear can arrive again while the inner one is still on screen.
        presentation.pushHost(outer)

        #expect(presentation.presents(inner), "the cover on top is still the one that can present")
    }

    @Test("the presentation returns to the router when the cover goes away")
    func leavingHandsItBack() {
        let presentation = NowPlayingPresentation()
        let cover = NowPlayingPresentation.HostToken()
        presentation.pushHost(cover)

        presentation.popHost(cover)

        #expect(presentation.routerPresents)
    }

    /// A release only ever comes from the side that owns the cover's item, never from the cover's
    /// own disappear: presenting the player takes its host off screen, and releasing there would
    /// dismiss the player in the update it appeared in. So a release while the player is up means
    /// the cover is really gone, and then the player changes hands rather than vanishing.
    @Test("a cover that goes away under the player hands it to the router")
    func releaseWhilePresentedFallsBackToTheRouter() {
        let presentation = NowPlayingPresentation()
        let cover = NowPlayingPresentation.HostToken()
        presentation.pushHost(cover)
        presentation.present()

        presentation.popHost(cover)

        #expect(presentation.routerPresents)
        #expect(presentation.isPresented, "the player stays on screen, it only changes presenter")
    }

    @Test("closing the player ends the presentation and lets the host go")
    func dismissReleasesTheHost() {
        let presentation = NowPlayingPresentation()
        let cover = NowPlayingPresentation.HostToken()
        presentation.pushHost(cover)
        presentation.present()

        presentation.dismiss()
        presentation.popHost(cover)

        #expect(presentation.isPresented == false)
        #expect(presentation.routerPresents)
    }

    @Test("a second request while the player is up changes nothing")
    func repeatedRequestIsIdempotent() {
        let presentation = NowPlayingPresentation()
        presentation.present()
        presentation.present()

        #expect(presentation.isPresented)
        presentation.dismiss()
        #expect(presentation.isPresented == false, "one dismissal has to be enough")
    }
}
