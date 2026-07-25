import SwiftUI

enum AccentAuroraMotion {
    static let primaryDuration: TimeInterval = 18
    static let secondaryDuration: TimeInterval = 20

    struct Sample {
        let primaryX: CGFloat
        let primaryY: CGFloat
        let secondaryX: CGFloat
        let secondaryY: CGFloat
    }

    static func sample(at time: TimeInterval) -> Sample {
        Sample(
            primaryX: 0.18 + 0.14 * wave(time, duration: primaryDuration),
            primaryY: 0.18 + 0.12 * wave(
                time + primaryDuration / 4,
                duration: primaryDuration
            ),
            secondaryX: 0.80 + 0.12 * wave(time, duration: secondaryDuration),
            secondaryY: 0.74 + 0.10 * wave(
                time + secondaryDuration / 4,
                duration: secondaryDuration
            )
        )
    }

    private static func wave(
        _ time: TimeInterval,
        duration: TimeInterval
    ) -> CGFloat {
        CGFloat(sin(time * 2 * .pi / duration))
    }
}

enum AccentAuroraGlow {
    /// Peak opacities already include the dimming that used to sit in a
    /// separate black overlay. One compositing step less means one 8 bit
    /// quantisation step less, which is where the banding came from.
    static let primaryIntensity: Double = 0.24
    static let secondaryIntensity: Double = 0.175

    static let primaryDiameterFraction: CGFloat = 1.02
    static let secondaryDiameterFraction: CGFloat = 0.88

    /// Normalised falloff, shaped to match the reach of the offscreen blur it
    /// replaces without rasterising an intermediate layer.
    static let profile: [SoftGradientStop] = [
        SoftGradientStop(opacity: 1, location: 0),
        SoftGradientStop(opacity: 0.92, location: 0.18),
        SoftGradientStop(opacity: 0.72, location: 0.38),
        SoftGradientStop(opacity: 0.44, location: 0.58),
        SoftGradientStop(opacity: 0.19, location: 0.76),
        SoftGradientStop(opacity: 0.05, location: 0.90),
        SoftGradientStop(opacity: 0, location: 1)
    ]

    static func stops(
        for color: Color,
        intensity: Double
    ) -> [Gradient.Stop] {
        profile.gradientStops(color, intensity: intensity)
    }
}

struct AccentAuroraBackground: View {
    let accent: Color
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { timeline in
            let time = isAnimating
                ? timeline.date.timeIntervalSinceReferenceDate
                : 0
            let motion = AccentAuroraMotion.sample(at: time)
            GeometryReader { proxy in
                let size = proxy.size
                let span = max(size.width, size.height)
                ZStack {
                    Color.black
                    glow(
                        intensity: AccentAuroraGlow.primaryIntensity,
                        diameter: span * AccentAuroraGlow.primaryDiameterFraction,
                        x: size.width * motion.primaryX,
                        y: size.height * motion.primaryY
                    )
                    glow(
                        intensity: AccentAuroraGlow.secondaryIntensity,
                        diameter: span * AccentAuroraGlow.secondaryDiameterFraction,
                        x: size.width * motion.secondaryX,
                        y: size.height * motion.secondaryY
                    )
                    LinearGradient(
                        colors: [.black.opacity(0.28), .clear, .black.opacity(0.34)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    BackgroundGrainLayer(opacity: BackgroundGrain.ditherOpacity)
                }
                .clipped()
            }
            .ignoresSafeArea()
        }
    }

    private func glow(
        intensity: Double,
        diameter: CGFloat,
        x: CGFloat,
        y: CGFloat
    ) -> some View {
        Circle()
            .fill(RadialGradient(
                stops: AccentAuroraGlow.stops(for: accent, intensity: intensity),
                center: .center,
                startRadius: 0,
                endRadius: diameter / 2
            ))
            .frame(width: diameter, height: diameter)
            .position(x: x, y: y)
    }
}
