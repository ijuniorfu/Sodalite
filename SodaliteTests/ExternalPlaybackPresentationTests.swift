import AVFoundation
import Foundation
import Testing

@testable import Sodalite

@Suite("External playback presentation (Sodalite#156)")
struct ExternalPlaybackPresentationTests {
    private func destination(_ ports: [(AVAudioSession.Port, String)]) -> ExternalPlaybackDestination {
        ExternalPlaybackPresentation.destination(ports: ports.map { (type: $0.0, name: $0.1) })
    }

    @Test("names the receiver a wireless route reports")
    func namesTheReceiver() {
        #expect(destination([(.airPlay, "Wohnzimmer")]) == .airPlay(name: "Wohnzimmer"))
    }

    @Test("a wired adapter is an external display, not a named device")
    func wiredCarriesNoName() {
        #expect(destination([(.HDMI, "HDMI")]) == .externalDisplay)
    }

    @Test("wired wins where an adapter exposes both ports")
    func wiredWinsOverWireless() {
        #expect(destination([(.airPlay, "Wohnzimmer"), (.HDMI, "HDMI")]) == .externalDisplay)
    }

    @Test("a route that names nothing usable falls back to the generic display")
    func unnamedRouteFallsBack() {
        #expect(destination([]) == .externalDisplay)
        #expect(destination([(.builtInSpeaker, "Speaker")]) == .externalDisplay)
    }

    @Test("a port that only repeats the protocol is not a device name")
    func protocolIsNotAName() {
        #expect(destination([(.airPlay, "AirPlay")]) == .airPlay(name: nil))
        #expect(destination([(.airPlay, "  ")]) == .airPlay(name: nil))
        #expect(ExternalPlaybackPresentation.displayName(forPort: " Wohnzimmer ") == "Wohnzimmer")
    }

    @Test("local picture controls and the auto-hide stand down while the picture is elsewhere")
    func localControlsStandDown() {
        #expect(ExternalPlaybackPresentation.localPictureControlsApply(destination: nil))
        #expect(ExternalPlaybackPresentation.autoHideApplies(destination: nil))
        for away: ExternalPlaybackDestination in [.airPlay(name: "Wohnzimmer"), .airPlay(name: nil), .externalDisplay] {
            #expect(!ExternalPlaybackPresentation.localPictureControlsApply(destination: away))
            #expect(!ExternalPlaybackPresentation.autoHideApplies(destination: away))
        }
    }

    @Test("the drop grace outlives a session-preserving reload without outliving a real disconnect")
    func dropGraceIsBounded() {
        #expect(ExternalPlaybackPresentation.dropGrace >= .milliseconds(1000))
        #expect(ExternalPlaybackPresentation.dropGrace <= .seconds(3))
    }

    // MARK: - Geometry

    /// iPhone 17 Pro, the device this was measured on, plus an iPad for the regular tier.
    private let phonePortrait: CGFloat = 932
    private let phoneLandscape: CGFloat = 430
    private let padLandscape: CGFloat = 834

    @Test("the band clears both scrims, so the transport never crosses the content")
    func bandClearsTheChrome() {
        for height in [phonePortrait, phoneLandscape, padLandscape] {
            let band = ExternalPlaybackPresentation.contentBand(screenHeight: height)
            #expect(band.minY >= PlayerOverlayView.titleScrimHeight(playerHeight: height))
            #expect(band.minY + band.height
                    <= height - PlayerOverlayView.controlScrimHeight(playerHeight: height) + 0.01)
        }
    }

    @Test("the band sits above the screen's own centre, which is what the report was about")
    func bandSitsHigherThanCentre() {
        let band = ExternalPlaybackPresentation.contentBand(screenHeight: phonePortrait)
        #expect(band.minY + band.height / 2 < phonePortrait / 2)
    }

    @Test("the poster and its text fit the band in every orientation")
    func contentFitsTheBand() {
        for (height, isPad) in [(phonePortrait, false), (phoneLandscape, false), (padLandscape, true)] {
            let band = ExternalPlaybackPresentation.contentBand(screenHeight: height).height
            let poster = ExternalPlaybackPresentation.posterHeight(bandHeight: band, isPad: isPad)
            let reserve = band < ExternalPlaybackPresentation.shortBandHeight
                ? ExternalPlaybackPresentation.shortTextBlockHeight
                : ExternalPlaybackPresentation.textBlockHeight
            #expect(poster + reserve <= band)
            #expect(poster > 0)
        }
    }

    @Test("a phone in landscape gets a visibly smaller poster than in portrait")
    func landscapeShrinksThePoster() {
        let portrait = ExternalPlaybackPresentation.posterHeight(
            bandHeight: ExternalPlaybackPresentation.contentBand(screenHeight: phonePortrait).height,
            isPad: false)
        let landscape = ExternalPlaybackPresentation.posterHeight(
            bandHeight: ExternalPlaybackPresentation.contentBand(screenHeight: phoneLandscape).height,
            isPad: false)
        #expect(landscape < portrait / 2)
    }

    @Test("an absurdly short band still leaves a poster rather than none")
    func degenerateBandKeepsAPoster() {
        #expect(ExternalPlaybackPresentation.posterHeight(bandHeight: 40, isPad: false) == 64)
    }
}
