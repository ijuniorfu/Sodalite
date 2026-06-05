import SwiftUI

/// The animated "now playing" waveform indicator, shared by the album
/// tracklist and the fullscreen player's queue so they look identical. The
/// bars pulse (variableColor) while playing and sit static when paused.
struct NowPlayingWaveIcon: View {
    let isPlaying: Bool
    var font: Font = .body

    var body: some View {
        Image(systemName: "waveform")
            .font(font)
            .foregroundStyle(.tint)
            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
    }
}
