import SwiftUI

struct ProgramInfoPopover: View {
    let program: JellyfinProgram
    let channel: JellyfinChannel
    let tint: Color
    /// Set by the tab to launch live playback when the user taps Watch Live.
    var onWatchLive: ((LivePlaybackContext) -> Void)?
    /// Initial favorite state of the channel and a callback to flip it.
    var channelIsFavorite: Bool = false
    var onToggleFavorite: (() -> Void)?
    /// Record state + toggles, provided by the guide's view model.
    var hasTimer: Bool = false
    var hasSeriesTimer: Bool = false
    var onToggleRecord: (() -> Void)?
    var onToggleSeriesRecord: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    /// Local mirror for snappy button feedback; the guide's view model holds
    /// the source of truth and persists to the server.
    @State private var isFavorite: Bool = false
    @State private var isRecording: Bool = false
    @State private var isSeriesRecording: Bool = false

    private var isAiring: Bool { program.isAiring(at: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(program.name).font(.title)
            if let start = program.startDate, let end = program.endDate {
                Text("\(channel.name) · \(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))")
                    .font(.headline).foregroundStyle(.secondary)
            }
            if let genres = program.genres, !genres.isEmpty {
                Text(genres.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let overview = program.overview {
                Text(overview).font(.body).lineLimit(8)
            }
            HStack(spacing: 20) {
                if isAiring {
                    PopoverActionButton(title: "livetv.watchLive", systemImage: "play.fill", accent: tint) {
                        dismiss()
                        onWatchLive?(LivePlaybackContext(channel: channel, program: program))
                    }
                }
                PopoverActionButton(
                    title: isFavorite ? "livetv.unfavorite" : "livetv.favorite",
                    systemImage: isFavorite ? "star.fill" : "star",
                    accent: isFavorite ? .yellow : tint
                ) {
                    isFavorite.toggle()
                    onToggleFavorite?()
                }
                // Record affordances: future or currently airing programs
                // only (a finished program cannot be recorded).
                if let end = program.endDate, end > Date() {
                    PopoverActionButton(
                        title: isRecording ? "livetv.cancelRecording" : "livetv.record",
                        systemImage: isRecording ? "stop.circle" : "record.circle",
                        accent: isRecording ? .red : tint
                    ) {
                        isRecording.toggle()
                        onToggleRecord?()
                    }
                    if program.isSeries == true {
                        PopoverActionButton(
                            title: isSeriesRecording ? "livetv.cancelSeriesRecording" : "livetv.recordSeries",
                            systemImage: isSeriesRecording ? "stop.circle.fill" : "record.circle.fill",
                            accent: isSeriesRecording ? .red : tint
                        ) {
                            isSeriesRecording.toggle()
                            onToggleSeriesRecord?()
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            isFavorite = channelIsFavorite
            isRecording = hasTimer
            isSeriesRecording = hasSeriesTimer
        }
    }
}

/// Popover action button. A raw `.focusable` surface, not a `Button`: tvOS's
/// default `Button` over a sheet renders only the focused button's label and
/// leaves the unfocused one a blank tinted pill. This always shows the label
/// (white on a translucent fill), and fills tinted when focused (the app's
/// focus convention), mirroring the Return-to-Live pill + BoolPillRow.
private struct PopoverActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let accent: Color
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .fontWeight(.semibold)
            .foregroundStyle(focused ? Color.black : .white)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(
                Capsule().fill(focused ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.12)))
            )
            .overlay(
                Capsule().strokeBorder(accent, lineWidth: focused ? 0 : 2)
            )
            .scaleEffect(focused ? 1.06 : 1.0)
            .focusable()
            .focused($focused)
            .animation(.easeInOut(duration: 0.15), value: focused)
            .stableTap(isFocused: focused) { action() }
    }
}
