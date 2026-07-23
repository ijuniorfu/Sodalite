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
                ZStack {
                    Color.black
                    glow(
                        color: accent,
                        diameter: max(size.width, size.height) * 0.72,
                        x: size.width * motion.primaryX,
                        y: size.height * motion.primaryY
                    )
                    glow(
                        color: accent.opacity(0.72),
                        diameter: max(size.width, size.height) * 0.62,
                        x: size.width * motion.secondaryX,
                        y: size.height * motion.secondaryY
                    )
                    Color.black.opacity(0.42)
                    LinearGradient(
                        colors: [.black.opacity(0.28), .clear, .black.opacity(0.34)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .clipped()
            }
            .ignoresSafeArea()
        }
    }

    private func glow(
        color: Color,
        diameter: CGFloat,
        x: CGFloat,
        y: CGFloat
    ) -> some View {
        Circle()
            .fill(color.opacity(0.42))
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.22)
            .position(x: x, y: y)
    }
}
