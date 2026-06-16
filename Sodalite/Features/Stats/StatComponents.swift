import SwiftUI

/// A single labelled number tile in the stats count grid. Focusable so
/// the otherwise non-focusable header (title + watch-time) above the grid
/// is reachable on tvOS: initial focus lands here and the focus engine can
/// scroll the header into view.
struct StatTile: View {
    let icon: String
    let value: String
    let label: LocalizedStringKey

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.tint)
            Text(value)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.white.opacity(focused ? 0.12 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.03 : 1.0)
        .focusable(true)
        .focused($focused)
        .animation(.easeInOut(duration: 0.2), value: focused)
    }
}

/// One genre row: name, a proportional bar, and the count. `fraction`
/// is the genre's share of the top genre (0...1) so the longest bar is
/// full-width.
struct GenreBar: View {
    let name: String
    let count: Int
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                Text(verbatim: "\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(8, geo.size.width * fraction))
                }
            }
            .frame(height: 10)
        }
    }
}
