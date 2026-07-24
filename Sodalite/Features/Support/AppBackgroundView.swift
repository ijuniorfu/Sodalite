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
    @Environment(\.backgroundSurfaceDepth) private var surfaceDepth
    @State private var visibility = BackgroundVisibilityMonitor.shared
    @State private var rendererToken = UUID()
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var playerActive = PlayerModalPresence.isPlayerActive

    private var isAutomaticRenderer: Bool {
        mode == .automatic
    }

    private var allowsMotion: Bool {
        guard mode != .static else { return false }
        return BackgroundMotionPolicy.allowsMotion(
            sceneActive: scenePhase == .active,
            reduceMotion: reduceMotion,
            lowPower: lowPower,
            playerActive: isAutomaticRenderer && playerActive,
            covered: isAutomaticRenderer
                && !visibility.permitsMotion(at: surfaceDepth)
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
            if isAutomaticRenderer {
                visibility.setRenderer(rendererToken, depth: surfaceDepth)
            }
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            playerActive = PlayerModalPresence.isPlayerActive
        }
        .onChange(of: surfaceDepth) { _, newDepth in
            if isAutomaticRenderer {
                visibility.setRenderer(rendererToken, depth: newDepth)
            }
        }
        .onDisappear {
            if isAutomaticRenderer {
                visibility.setRenderer(rendererToken, depth: nil)
            }
        }
    }
}
