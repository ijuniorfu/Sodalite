import SwiftUI
import UIKit

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
                        .fill(ImagePaint(image: Image(uiImage: Self.grain), scale: 1))
                        .scaleEffect(1.08)
                        .offset(
                            x: motion.grainOffsetX,
                            y: motion.grainOffsetY
                        )
                        .opacity(0.08)
                    Rectangle()
                        .fill(LinearGradient(
                            colors: [.clear, Color(red: 1, green: 0.88, blue: 0.70).opacity(0.12), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: proxy.size.width * 0.72)
                        .rotationEffect(.degrees(-7))
                        .offset(x: motion.lightOffsetX * proxy.size.width)
                    Color.black.opacity(0.28)
                }
            }
            .ignoresSafeArea()
        }
    }

    private static let grain: UIImage = {
        var seed: UInt64 = 0x534F44414C495445
        func next() -> UInt8 {
            seed = 6364136223846793005 &* seed &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: seed >> 40)
        }
        return UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { context in
            let cg = context.cgContext
            for y in 0..<96 {
                for x in 0..<96 {
                    let value = CGFloat(next()) / 255
                    cg.setFillColor(UIColor(white: value, alpha: 1).cgColor)
                    cg.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }()
}
