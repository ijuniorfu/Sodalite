import Foundation
import Testing
@testable import Sodalite

@Suite("Background renderer geometry")
struct BackgroundRendererGeometryTests {
    @Test("noir sweep keeps every stop on its axis for the whole cycle")
    func noirSweepStaysOnAxis() {
        for step in 0...72 {
            let time = CinemaNoirMotion.lightDuration * Double(step) / 72
            let offset = CinemaNoirMotion.sample(at: time).lightOffsetX
            let shaped = CinemaNoirLightBeam.shapedProfile(
                travel: CinemaNoirLightBeam.travel(forOffset: offset)
            )

            #expect(shaped.first?.location == 0)
            #expect(shaped.last?.location == 1)
            #expect(shaped.first?.opacity == 0)
            #expect(shaped.last?.opacity == 0)

            for (lower, upper) in zip(shaped, shaped.dropFirst()) {
                #expect(upper.location >= lower.location)
            }
        }
    }

    @Test("noir sweep travels across most of the surface")
    func noirSweepTravel() {
        let axisSpan = 1 + 2 * CinemaNoirLightBeam.axisOvershoot
        func surfacePosition(atOffset offset: CGFloat) -> Double {
            CinemaNoirLightBeam.travel(forOffset: offset)
                * axisSpan - CinemaNoirLightBeam.axisOvershoot
        }

        let leftmost = surfacePosition(atOffset: -CinemaNoirMotion.lightAmplitude)
        let rightmost = surfacePosition(atOffset: CinemaNoirMotion.lightAmplitude)
        #expect(rightmost - leftmost >= 0.8)
        #expect(leftmost >= 0)
        #expect(rightmost <= 1)
    }

    @Test("noir light beam fades in and out along its travel axis")
    func noirBeamProfile() {
        let profile = CinemaNoirLightBeam.profile
        #expect(profile.count >= 5)
        #expect(profile.first?.opacity == 0)
        #expect(profile.last?.opacity == 0)
        #expect(profile.first?.location == 0)
        #expect(profile.last?.location == 1)
        #expect(profile.map(\.location) == profile.map(\.location).sorted())

        let peak = profile.max { $0.opacity < $1.opacity }
        #expect(peak != nil)
        #expect(abs((peak?.location ?? 0) - 0.5) < 0.0001)
    }

    @Test("aurora glow falls off smoothly to full transparency")
    func auroraGlowProfile() {
        let profile = AccentAuroraGlow.profile
        #expect(profile.count >= 5)
        #expect(profile.first?.location == 0)
        #expect(profile.last?.location == 1)
        #expect(profile.last?.opacity == 0)

        for (inner, outer) in zip(profile, profile.dropFirst()) {
            #expect(outer.location > inner.location)
            #expect(outer.opacity <= inner.opacity)
        }
    }

    @Test("dither breaks quantisation without lifting black surfaces")
    func ditherStrength() {
        #expect(BackgroundGrain.ditherOpacity >= 0.02)
        #expect(BackgroundGrain.ditherOpacity <= 0.04)
        #expect(BackgroundGrain.filmOpacity > BackgroundGrain.ditherOpacity)
    }

    @Test("aurora shapes its glows as gradients instead of blurring offscreen")
    func auroraUsesGradientFalloff() throws {
        let source = try sourceFile(
            "Sodalite/Features/Support/AccentAuroraBackground.swift"
        )
        #expect(!source.contains(".blur("))
        #expect(source.contains("RadialGradient"))
        #expect(source.contains("AccentAuroraGlow.stops"))
        #expect(source.contains("BackgroundGrainLayer"))
    }

    /// The beam used to be a sized, rotated Rectangle, which inflated the
    /// ZStack around it and dragged its own edge into frame. Nothing in this
    /// renderer may carry a size of its own again.
    @Test("noir light carries no geometry that can expose an edge")
    func noirLightHasNoGeometry() throws {
        let source = try sourceFile(
            "Sodalite/Features/Support/CinemaNoirBackground.swift"
        )
        #expect(!source.contains("rotationEffect"))
        #expect(!source.contains(".frame("))
        #expect(!source.contains("UIGraphicsImageRenderer"))
        #expect(source.contains("BackgroundGrainLayer"))
        #expect(source.contains("CinemaNoirLightBeam.stops"))
    }

    /// Grain that drifts slowly reads as a crawling pattern instead of grain.
    /// Neither renderer may move its texture, and the layer must not offer a
    /// way to do so.
    @Test("grain never moves in either renderer")
    func grainIsStatic() throws {
        for path in [
            "Sodalite/Features/Support/CinemaNoirBackground.swift",
            "Sodalite/Features/Support/AccentAuroraBackground.swift"
        ] {
            let source = try sourceFile(path)
            #expect(!source.contains("grainOffset"))
        }

        let primitives = try sourceFile(
            "Sodalite/Features/Support/BackgroundRenderPrimitives.swift"
        )
        #expect(!primitives.contains("scaleEffect"))
        #expect(!primitives.contains(".offset("))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
