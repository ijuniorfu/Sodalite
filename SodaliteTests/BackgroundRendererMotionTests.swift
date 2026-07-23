import Foundation
import Testing
@testable import Sodalite

@Suite("Background renderer motion")
struct BackgroundRendererMotionTests {
    @Test("aurora travels visibly within one quarter cycle")
    func auroraTravel() {
        let start = AccentAuroraMotion.sample(at: 0)
        let quarter = AccentAuroraMotion.sample(
            at: AccentAuroraMotion.primaryDuration / 4
        )
        #expect(abs(quarter.primaryX - start.primaryX) >= 0.12)
        #expect(abs(quarter.secondaryY - start.secondaryY) >= 0.08)
    }

    @Test("aurora primary motion repeats after its cycle")
    func auroraRepeats() {
        let start = AccentAuroraMotion.sample(at: 0)
        let repeated = AccentAuroraMotion.sample(
            at: AccentAuroraMotion.primaryDuration
        )
        #expect(abs(repeated.primaryX - start.primaryX) < 0.0001)
        #expect(abs(repeated.primaryY - start.primaryY) < 0.0001)
    }

    @Test("noir light crosses a meaningful part of the canvas")
    func noirTravel() {
        let start = CinemaNoirMotion.sample(at: 0)
        let quarter = CinemaNoirMotion.sample(
            at: CinemaNoirMotion.lightDuration / 4
        )
        #expect(abs(quarter.lightOffsetX - start.lightOffsetX) >= 0.40)
        #expect(quarter.grainOffsetX != start.grainOffsetX)
    }

    @Test("static renderer samples start from a composed frame")
    func staticSamples() {
        let aurora = AccentAuroraMotion.sample(at: 0)
        let noir = CinemaNoirMotion.sample(at: 0)
        #expect((0...1).contains(aurora.primaryX))
        #expect((0...1).contains(aurora.primaryY))
        #expect(abs(noir.lightOffsetX) <= 0.5)
    }
}
