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

    var isCovered: Bool { !coverTokens.isEmpty }
    var coverCount: Int { coverTokens.count }

    func setCover(_ token: UUID, presented: Bool) {
        if presented {
            coverTokens.insert(token)
        } else {
            coverTokens.remove(token)
        }
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
