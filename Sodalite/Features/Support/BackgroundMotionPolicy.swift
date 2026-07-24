import Observation
import SwiftUI

enum BackgroundMotionPolicy {
    static func allowsMotion(
        sceneActive: Bool,
        reduceMotion: Bool,
        lowPower: Bool,
        playerActive: Bool,
        covered: Bool
    ) -> Bool {
        sceneActive
            && !reduceMotion
            && !lowPower
            && !playerActive
            && !covered
    }
}

@MainActor
@Observable
final class BackgroundVisibilityMonitor {
    static let shared = BackgroundVisibilityMonitor()
    private var coverTokens: Set<UUID> = []
    private var rendererDepths: [UUID: Int] = [:]

    var isCovered: Bool { !coverTokens.isEmpty }
    var coverCount: Int { coverTokens.count }
    var rendererCount: Int { rendererDepths.count }
    var highestRendererDepth: Int? { rendererDepths.values.max() }

    func setCover(_ token: UUID, presented: Bool) {
        if presented {
            coverTokens.insert(token)
        } else {
            coverTokens.remove(token)
        }
    }

    func setRenderer(_ token: UUID, depth: Int?) {
        if let depth {
            rendererDepths[token] = depth
        } else {
            rendererDepths.removeValue(forKey: token)
        }
    }

    func permitsMotion(at depth: Int) -> Bool {
        !isCovered && highestRendererDepth == depth
    }
}

private struct BackgroundSurfaceDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var backgroundSurfaceDepth: Int {
        get { self[BackgroundSurfaceDepthKey.self] }
        set { self[BackgroundSurfaceDepthKey.self] = newValue }
    }
}

private struct BackgroundCoverPresenceModifier: ViewModifier {
    @State private var token = UUID()
    @State private var monitor = BackgroundVisibilityMonitor.shared

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.setCover(token, presented: true) }
            .onDisappear { monitor.setCover(token, presented: false) }
    }
}

extension View {
    func pausesAppBackgroundMotion() -> some View {
        modifier(BackgroundCoverPresenceModifier())
    }
}
