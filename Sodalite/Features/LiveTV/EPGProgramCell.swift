import SwiftUI

/// One program block in the EPG grid. Focusable via the project's
/// canonical `stableTap`; fills with the tint when focused (never white).
struct EPGProgramCell: View {
    let program: JellyfinProgram
    let width: CGFloat
    let tint: Color
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(program.name)
                .font(.headline)
                .lineLimit(1)
            if let start = program.startDate, let end = program.endDate {
                Text("\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: max(width, 8), height: EPGGuideViewModel.rowHeight - 8, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isFocused ? tint : Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .focusable(true)
        .focused($isFocused)
        .stableTap(isFocused: isFocused, perform: onSelect)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

/// Shown for a channel that returned no program data; still selectable so
/// the user can tune in live.
struct EPGPlaceholderCell: View {
    let width: CGFloat
    let tint: Color
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Text("livetv.noProgramInfo")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(width: max(width, 200), height: EPGGuideViewModel.rowHeight - 8, alignment: .leading)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isFocused ? tint : Color.white.opacity(0.05))
            )
            .focusable(true)
            .focused($isFocused)
            .stableTap(isFocused: isFocused, perform: onSelect)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
