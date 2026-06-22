import SwiftUI

/// Animated waveform indicator, shared by the album tracklist and player queue; pulses (variableColor) while playing, static when paused.
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
