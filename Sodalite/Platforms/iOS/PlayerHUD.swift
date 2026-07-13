import SwiftUI

/// Transient HUD for brightness/volume swipes and skip ripples. Reads the view model's hud state
/// (kind + 0...1 level) and is shown/auto-faded by the overlay.
struct PlayerHUD: View {
    let kind: PlayerViewModel.PlayerHUDKind
    let level: Double

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                // Swap the glyph instantly instead of cross-morphing it: the overlay fades in via opacity,
                // and without this the symbol would animate from the previous kind (the skip glyph) into
                // the new one as it appears.
                .contentTransition(.identity)
            if kind == .brightness || kind == .volume {
                ProgressView(value: min(max(level, 0), 1))
                    .frame(width: 120)
                    .tint(.white)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(.white)
    }

    private var icon: String {
        switch kind {
        case .brightness: return "sun.max.fill"
        case .volume: return level <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .skipForward: return "goforward.10"
        case .skipBackward: return "gobackward.10"
        }
    }
}
