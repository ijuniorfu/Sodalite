import SwiftUI

struct ProgramInfoPopover: View {
    let program: JellyfinProgram
    let channel: JellyfinChannel
    let tint: Color
    /// Set by the tab to launch live playback when the user taps Watch Live.
    var onWatchLive: ((LivePlaybackContext) -> Void)?

    @Environment(\.dismiss) private var dismiss

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
                    Button {
                        dismiss()
                        onWatchLive?(LivePlaybackContext(channel: channel, program: program))
                    } label: {
                        Label("livetv.watchLive", systemImage: "play.fill")
                    }
                    .tint(tint)
                }
                // Record affordance reserved for the recordings sub-project.
            }
            Spacer()
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
