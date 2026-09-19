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
}
