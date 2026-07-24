import SwiftUI

enum BackgroundMotionMode: Equatable {
    case automatic
    case preview
    case `static`
}

struct AppBackgroundView: View {
    let theme: ResolvedAppearanceTheme
    let mode: BackgroundMotionMode

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibility = BackgroundVisibilityMonitor.shared
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var playerActive = PlayerModalPresence.isPlayerActive

    private var allowsMotion: Bool {
        guard mode != .static else { return false }
        let isShellRenderer = mode == .automatic
        return BackgroundMotionPolicy.allowsMotion(
            sceneActive: scenePhase == .active,
            reduceMotion: reduceMotion,
            lowPower: lowPower,
            playerActive: isShellRenderer && playerActive,
            covered: isShellRenderer && visibility.isCovered
        )
    }

    var body: some View {
        Group {
            switch theme.background {
            case .graphiteGlass:
                GraphiteGlassBackground()
            case .oledBlack:
                Color.black.ignoresSafeArea()
            case .accentAurora:
                AccentAuroraBackground(
                    accent: theme.palette.control.color,
                    isAnimating: allowsMotion
                )
            case .cinemaNoir:
                CinemaNoirBackground(isAnimating: allowsMotion)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .NSProcessInfoPowerStateDidChange
        )) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .playerModalPresenceDidChange
        )) { _ in
            playerActive = PlayerModalPresence.isPlayerActive
        }
        .onAppear {
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            playerActive = PlayerModalPresence.isPlayerActive
        }
    }
}
