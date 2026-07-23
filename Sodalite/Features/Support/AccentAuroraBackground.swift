import SwiftUI

struct AccentAuroraBackground: View {
    let accent: Color
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { timeline in
            let time = isAnimating
                ? timeline.date.timeIntervalSinceReferenceDate
                : 0
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    Color.black
                    glow(
                        color: accent,
                        diameter: max(size.width, size.height) * 0.72,
                        x: size.width * (0.16 + 0.08 * sin(time / 8)),
                        y: size.height * (0.12 + 0.07 * cos(time / 9))
                    )
                    glow(
                        color: accent.opacity(0.72),
                        diameter: max(size.width, size.height) * 0.62,
                        x: size.width * (0.82 + 0.06 * cos(time / 10)),
                        y: size.height * (0.78 + 0.08 * sin(time / 11))
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
