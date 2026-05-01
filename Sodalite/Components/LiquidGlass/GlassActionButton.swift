import SwiftUI

struct GlassActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isProminent: Bool = false
    /// Optional secondary line below the title — used by the detail-
    /// view resume button to surface the resume timestamp ("12:34")
    /// without changing the button's footprint dramatically. Renders
    /// in caption2 + 0.75 opacity so it reads as supporting metadata,
    /// not a competing label.
    var subtitle: String? = nil
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body)
                Text(title)
                    .font(.callout)
                    .fontWeight(.medium)
                // Subtitle sits inline next to the title rather than
                // stacked below it. Two-line buttons would make this
                // one taller than its row neighbours (Replay, Favorite,
                // Request) and the action row would lose its visual
                // grid; widening is the cheaper trade on a 10-foot UI.
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .buttonStyle(GlassButtonStyle(isProminent: isProminent))
    }
}

struct GlassButtonStyle: ButtonStyle {
    var isProminent: Bool = false
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule()
                    .fill(backgroundFill)
            )
            .overlay(
                Capsule()
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
            )
            .scaleEffect(isFocused ? 1.08 : (configuration.isPressed ? 0.95 : 1.0))
            .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 10, y: 5)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }

    private var backgroundFill: AnyShapeStyle {
        if isProminent {
            return AnyShapeStyle(isFocused ? Color.accentColor.opacity(0.9) : Color.accentColor.opacity(0.7))
        }
        return AnyShapeStyle(isFocused ? .white.opacity(0.2) : .white.opacity(0.1))
    }
}
