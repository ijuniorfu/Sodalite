import Foundation
import Testing
@testable import Sodalite

@Suite("Background renderer geometry")
struct BackgroundRendererGeometryTests {
    private let canvases = [
        CGSize(width: 1920, height: 1080),
        CGSize(width: 3840, height: 2160),
        CGSize(width: 1024, height: 768),
        CGSize(width: 393, height: 852),
        CGSize(width: 852, height: 393)
    ]

    @Test("noir light beam never exposes a horizontal edge")
    func noirBeamCoversEveryCanvas() {
        for canvas in canvases {
            let halfHeight = CinemaNoirLightBeam.height(for: canvas) / 2
            for step in 0...36 {
                let time = CinemaNoirMotion.lightDuration * Double(step) / 36
                let offsetX = CinemaNoirMotion.sample(at: time).lightOffsetX
                    * canvas.width
                #expect(halfHeight >= maxBeamSpan(canvas: canvas, offsetX: offsetX))
            }
        }
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

    @Test("noir reuses the shared grain texture and the oversized beam")
    func noirUsesSharedPrimitives() throws {
        let source = try sourceFile(
            "Sodalite/Features/Support/CinemaNoirBackground.swift"
        )
        #expect(!source.contains("UIGraphicsImageRenderer"))
        #expect(source.contains("BackgroundGrainLayer"))
        #expect(source.contains("CinemaNoirLightBeam.height(for:"))
        #expect(source.contains("CinemaNoirLightBeam.stops"))
    }

    /// Largest distance any canvas corner reaches along the beam's own
    /// vertical axis. The beam must be at least twice that tall, otherwise
    /// its rotated top or bottom edge cuts into the visible frame.
    private func maxBeamSpan(canvas: CGSize, offsetX: CGFloat) -> CGFloat {
        let radians = CinemaNoirLightBeam.angleDegrees * .pi / 180
        let axis = CGPoint(x: -sin(radians), y: cos(radians))
        let centre = CGPoint(
            x: canvas.width / 2 + offsetX,
            y: canvas.height / 2
        )
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: canvas.width, y: 0),
            CGPoint(x: 0, y: canvas.height),
            CGPoint(x: canvas.width, y: canvas.height)
        ]
        return corners
            .map { abs(($0.x - centre.x) * axis.x + ($0.y - centre.y) * axis.y) }
            .max() ?? 0
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
