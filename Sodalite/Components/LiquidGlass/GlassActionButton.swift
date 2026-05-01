import SwiftUI

struct GlassActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isProminent: Bool = false
    /// Optional inline secondary label — used by the detail-view
    /// resume button to surface "S1E5 · 12:34" without breaking row
    /// height. Renders in caption + 0.75 opacity so it reads as
    /// supporting metadata, not a competing title.
    var subtitle: String? = nil
    /// Optional 0…1 progress overlay drawn behind the button label.
    /// Used by the resume button to mirror Apple TV+'s convention of
    /// painting the user's progress through the title across the
    /// resume tile in the active accent. nil suppresses the overlay
    /// entirely (fresh content, no progress to show).
    var progressFraction: Double? = nil
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
        .buttonStyle(GlassButtonStyle(
            isProminent: isProminent,
            progressFraction: progressFraction
        ))
    }
}

struct GlassButtonStyle: ButtonStyle {
    var isProminent: Bool = false
    /// 0…1, ignored when nil. Drives the resume-progress fill rendered
    /// behind the label. The bar wears the accent tint so it picks up
    /// whatever colour the user has selected for the rest of the UI.
    var progressFraction: Double? = nil
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                ZStack(alignment: .leading) {
                    // Base capsule — same fill the button has always
                    // drawn. The progress overlay above sits on top of
                    // this so a half-watched item still shows the
                    // remaining-bar background colour for the right
                    // half of the tile.
                    Capsule()
                        .fill(backgroundFill)

                    if let fraction = progressFraction, fraction > 0 {
                        GeometryReader { geo in
                            Capsule()
                                .fill(.tint.opacity(isFocused ? 0.55 : 0.4))
                                .frame(width: geo.size.width * CGFloat(min(1.0, fraction)))
                        }
                        // Shape the inner fill to the outer capsule so
                        // a fraction near 1.0 doesn't bleed past the
                        // pill's rounded edge on either side.
                        .clipShape(Capsule())
                    }
                }
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
