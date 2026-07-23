import SwiftUI

private struct CrystalFacet: Shape {
    let points: [UnitPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(
            x: rect.minX + first.x * rect.width,
            y: rect.minY + first.y * rect.height
        ))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(
                x: rect.minX + point.x * rect.width,
                y: rect.minY + point.y * rect.height
            ))
        }
        path.closeSubpath()
        return path
    }
}

struct PolishedCrystalBackground: View {
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { timeline in
            let time = isAnimating
                ? timeline.date.timeIntervalSinceReferenceDate
                : 0
            let sweep = isAnimating
                ? CGFloat((time.truncatingRemainder(dividingBy: 12)) / 12)
                : 0.5
            GeometryReader { proxy in
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.06, green: 0.07, blue: 0.11), .black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    facet(
                        points: [.init(x: 0.40, y: 0), .init(x: 1, y: 0.16),
                                 .init(x: 0.88, y: 0.82), .init(x: 0.28, y: 0.66)],
                        colors: [Color(red: 0.32, green: 0.58, blue: 0.90),
                                 Color(red: 0.28, green: 0.18, blue: 0.62)]
                    )
                    .offset(x: proxy.size.width * 0.08)
                    facet(
                        points: [.init(x: 0, y: 0.36), .init(x: 0.42, y: 0.22),
                                 .init(x: 0.58, y: 1), .init(x: 0, y: 0.88)],
                        colors: [Color(red: 0.12, green: 0.67, blue: 0.70),
                                 Color(red: 0.13, green: 0.29, blue: 0.58)]
                    )
                    specularSweep(width: proxy.size.width, progress: sweep)
                    Color.black.opacity(0.42)
                }
                .clipped()
            }
            .ignoresSafeArea()
        }
    }

    private func facet(points: [UnitPoint], colors: [Color]) -> some View {
        CrystalFacet(points: points)
            .fill(LinearGradient(
                colors: colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .opacity(0.46)
            .overlay {
                CrystalFacet(points: points)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
    }

    private func specularSweep(width: CGFloat, progress: CGFloat) -> some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [.clear, .white.opacity(0.04), .white.opacity(0.34),
                         .white.opacity(0.05), .clear],
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(width: width * 0.34)
            .rotationEffect(.degrees(-10))
            .blur(radius: 8)
            .offset(x: -width * 0.72 + progress * width * 1.44)
            .allowsHitTesting(false)
    }
}
