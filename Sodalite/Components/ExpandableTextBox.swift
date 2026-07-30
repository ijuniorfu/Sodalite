import SwiftUI

struct ExpandableTextBox: View {
    let text: String
    /// Sodalite#50. nil keeps the component exactly as it was for callers with nothing to spoil.
    var spoilerItem: JellyfinItem?

    @State private var showFullText = false
    @FocusState private var isFocused: Bool

    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

    private var isSpoilerHidden: Bool {
        guard let spoilerItem else { return false }
        return SpoilerReveal.isHidden(spoilerItem, dependencies: dependencies, appState: appState)
    }

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 110)
            // Sodalite#50: only the text is veiled, the material and the focus stroke stay sharp.
            .spoilerVeil(isHidden: isSpoilerHidden, style: .text)
            .padding(20)
            .background(
                // Material base (not a faint white tint) so body text keeps contrast over bright full-bleed artwork (Sodalite#15).
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isFocused ? .white.opacity(0.1) : .clear)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .focusable()
            .focused($isFocused)
            .stableTap(isFocused: isFocused) {
                // Sodalite#50: same two-step as EpisodeSynopsisBox, uncover first, expand second.
                if let spoilerItem, isSpoilerHidden {
                    SpoilerReveal.reveal(spoilerItem, dependencies: dependencies, appState: appState)
                    return
                }
                showFullText = true
            }
            .fullScreenCover(isPresented: $showFullText) {
                TextOverlay(text: text, isPresented: $showFullText)
            }
    }
}

/// Matches ExpandableTextBox's footprint so the overview box doesn't pop in and shift layout while the detail fetch is in flight.
struct ExpandableTextBoxPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.white.opacity(0.04))
            .frame(maxWidth: .infinity)
            .frame(height: 150)
    }
}

struct TextOverlay: View {
    let text: String
    @Binding var isPresented: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()

            ScrollView {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(60)
                    .frame(maxWidth: 1200)
            }
            .focusable()
            .focused($isFocused)

            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(40)
                }
                Spacer()
            }
        }
    }
}
