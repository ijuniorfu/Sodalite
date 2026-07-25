import SwiftUI

enum CinemaNoirMotion {
    static let lightDuration: TimeInterval = 18
    private static let grainXDuration: TimeInterval = 36
    private static let grainYDuration: TimeInterval = 42

    struct Sample {
        let lightOffsetX: CGFloat
        let grainOffsetX: CGFloat
        let grainOffsetY: CGFloat
    }

    static func sample(at time: TimeInterval) -> Sample {
        Sample(
            lightOffsetX: 0.46 * wave(time, duration: lightDuration),
            grainOffsetX: 8 * wave(time, duration: grainXDuration),
            grainOffsetY: 6 * wave(
                time + grainYDuration / 4,
                duration: grainYDuration
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

enum CinemaNoirLightBeam {
    static let angleDegrees: CGFloat = -7
    static let widthFraction: CGFloat = 0.72

    /// The beam is rotated, so a canvas sized sheet drags its own top and
    /// bottom edges into frame. Sizing it past the diagonal keeps every edge
    /// outside the visible area at any travel offset.
    static let heightFactor: CGFloat = 1.6

    static let tint = Color(red: 1, green: 0.88, blue: 0.70)

    static let profile: [SoftGradientStop] = [
        SoftGradientStop(opacity: 0, location: 0),
        SoftGradientStop(opacity: 0.03, location: 0.24),
        SoftGradientStop(opacity: 0.09, location: 0.38),
        SoftGradientStop(opacity: 0.12, location: 0.5),
        SoftGradientStop(opacity: 0.09, location: 0.62),
        SoftGradientStop(opacity: 0.03, location: 0.76),
        SoftGradientStop(opacity: 0, location: 1)
    ]

    static func height(for size: CGSize) -> CGFloat {
        hypot(size.width, size.height) * heightFactor
    }

    static func stops() -> [Gradient.Stop] {
        profile.gradientStops(tint)
    }
}

struct CinemaNoirBackground: View {
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { timeline in
            let time = isAnimating
                ? timeline.date.timeIntervalSinceReferenceDate
                : 0
            let motion = CinemaNoirMotion.sample(at: time)
            GeometryReader { proxy in
                ZStack {
                    RadialGradient(
                        colors: [Color(white: 0.24), Color(white: 0.05), .black],
                        center: .top,
                        startRadius: 0,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.82
                    )
                    Rectangle()
                        .fill(LinearGradient(
                            stops: CinemaNoirLightBeam.stops(),
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(
                            width: proxy.size.width * CinemaNoirLightBeam.widthFraction,
                            height: CinemaNoirLightBeam.height(for: proxy.size)
                        )
                        .rotationEffect(.degrees(CinemaNoirLightBeam.angleDegrees))
                        .offset(x: motion.lightOffsetX * proxy.size.width)
                    Color.black.opacity(0.28)
                    BackgroundGrainLayer(
                        opacity: BackgroundGrain.filmOpacity,
                        scale: 1.08,
                        offset: CGSize(
                            width: motion.grainOffsetX,
                            height: motion.grainOffsetY
                        )
                    )
                }
                .clipped()
            }
            .ignoresSafeArea()
        }
    }
}
