import SwiftUI

enum CinemaNoirMotion {
    static let lightDuration: TimeInterval = 18
    static let lightAmplitude: CGFloat = 0.46

    struct Sample {
        let lightOffsetX: CGFloat
    }

    static func sample(at time: TimeInterval) -> Sample {
        Sample(lightOffsetX: lightAmplitude * wave(time, duration: lightDuration))
    }

    private static func wave(
        _ time: TimeInterval,
        duration: TimeInterval
    ) -> CGFloat {
        CGFloat(sin(time * 2 * .pi / duration))
    }
}

/// The light is a gradient across the whole surface, not a shape drawn on top
/// of it. Any sized or rotated layer eventually drags one of its own edges into
/// frame, so there is no geometry here to expose.
enum CinemaNoirLightBeam {
    /// The gradient axis runs past both frame edges, which leaves room for the
    /// sweep to sit near a border without a stop ever needing to be clamped.
    static let axisOvershoot: Double = 0.4
    static let axisTilt: Double = 0.16
    static let peakHalfWidth: Double = 0.25

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

    static var startPoint: UnitPoint {
        UnitPoint(x: -axisOvershoot, y: 0.5 - axisTilt)
    }

    static var endPoint: UnitPoint {
        UnitPoint(x: 1 + axisOvershoot, y: 0.5 + axisTilt)
    }

    /// Maps the travel wave onto the axis so the peak stays far enough from
    /// both ends for the full profile to fit.
    static func travel(forOffset offset: CGFloat) -> Double {
        let reach = 0.5 - peakHalfWidth
        return 0.5 + Double(offset / CinemaNoirMotion.lightAmplitude) * reach
    }

    static func shapedProfile(travel: Double) -> [SoftGradientStop] {
        let leading = travel - peakHalfWidth
        let trailing = travel + peakHalfWidth
        var shaped: [SoftGradientStop] = []
        if leading > 0 {
            shaped.append(SoftGradientStop(opacity: 0, location: 0))
        }
        shaped += profile.map {
            SoftGradientStop(
                opacity: $0.opacity,
                location: min(1, max(0, leading + $0.location * 2 * peakHalfWidth))
            )
        }
        if trailing < 1 {
            shaped.append(SoftGradientStop(opacity: 0, location: 1))
        }
        return shaped
    }

    static func stops(travel: Double) -> [Gradient.Stop] {
        shapedProfile(travel: travel).gradientStops(tint)
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
                            stops: CinemaNoirLightBeam.stops(
                                travel: CinemaNoirLightBeam.travel(
                                    forOffset: motion.lightOffsetX
                                )
                            ),
                            startPoint: CinemaNoirLightBeam.startPoint,
                            endPoint: CinemaNoirLightBeam.endPoint
                        ))
                    Color.black.opacity(0.28)
                    BackgroundGrainLayer(opacity: BackgroundGrain.filmOpacity)
                }
            }
            .ignoresSafeArea()
        }
    }
}
