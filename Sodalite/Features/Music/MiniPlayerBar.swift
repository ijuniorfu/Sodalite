import SwiftUI

/// A persistent floating bar that surfaces the current music track
/// across all tabs. Shown only while `MusicPlaybackCoordinator.currentItem`
/// is non-nil; invisible otherwise so it never intrudes on the tab UI,
/// login screens, or the video player.
///
/// Focus model:
/// - The whole bar is a single focusable tile (stableTap opens NowPlayingView).
/// - The play/pause button is a second focusable control embedded inside the bar.
///
/// Background: `.regularMaterial` (consistent with other overlay surfaces
/// in the app, e.g. ServerSwitchSheet, TVUserProfileSettingsView).
struct MiniPlayerBar: View {
    @Binding var isNowPlayingPresented: Bool

    @Environment(\.dependencies) private var dependencies

    /// Focus state for the bar's primary tap target (opens NowPlaying).
    @FocusState private var barFocused: Bool

    var body: some View {
        let coordinator = dependencies.musicPlaybackCoordinator
        if coordinator.currentItem != nil {
            barContent(coordinator: coordinator)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func barContent(coordinator: MusicPlaybackCoordinator) -> some View {
        // currentItem is guaranteed non-nil here; force-unwrap is safe
        // because the caller (body) already checked and SwiftUI renders this
        // path only when true. Use local let to avoid repeated optional chaining.
        let item = coordinator.currentItem!

        ZStack(alignment: .bottom) {
            // Thin progress line across the very bottom of the bar.
            GeometryReader { geo in
                Rectangle()
                    .fill(.tint.opacity(0.85))
                    .frame(
                        width: geo.size.width * CGFloat(coordinator.currentTime / max(coordinator.duration, 1)),
                        height: 3
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(height: 3)

            HStack(spacing: 20) {
                // Cover art: prefer album art when available, fall back to
                // item's own primary image (same logic as +NowPlaying).
                let coverURL: URL? = {
                    if let albumID = item.albumId, let albumTag = item.albumPrimaryImageTag {
                        return dependencies.jellyfinImageService.imageURL(
                            itemID: albumID,
                            imageType: .primary,
                            tag: albumTag,
                            maxWidth: 120
                        )
                    }
                    return dependencies.jellyfinImageService.posterURL(for: item, maxWidth: 120)
                }()

                AsyncCachedImage(url: coverURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.1))
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        )
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Title + artist
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(barFocused ? .white : Color.primary)
                        .lineLimit(1)

                    if let artist = item.trackArtistLine {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(barFocused ? Color.white.opacity(0.75) : Color.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Play/Pause button: own focusable control.
                PlayPauseButton(
                    isPlaying: coordinator.isPlaying,
                    onToggle: { coordinator.togglePlayPause() }
                )
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 16)
            .padding(.bottom, 3) // leave room for the progress line
        }
        .background(.regularMaterial)
        // Tint stroke mirrors the TrackRow convention.
        .overlay(
            Rectangle()
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(barFocused ? 1 : 0)
        )
        .scaleEffect(barFocused ? 1.01 : 1.0)
        .shadow(color: .black.opacity(barFocused ? 0.35 : 0.15), radius: 20, y: -4)
        .focusable(true)
        .focused($barFocused)
        .animation(.easeInOut(duration: 0.15), value: barFocused)
        .stableTap(isFocused: barFocused) {
            isNowPlayingPresented = true
        }
    }
}

// MARK: - Play/Pause Button

private struct PlayPauseButton: View {
    let isPlaying: Bool
    let onToggle: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button {
            onToggle()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
                .frame(width: 52, height: 52)
                .background(
                    Circle()
                        .fill(.white.opacity(focused ? 0.2 : 0.08))
                )
                .overlay(
                    Circle()
                        .strokeBorder(.tint, lineWidth: 3)
                        .opacity(focused ? 1 : 0)
                )
                .scaleEffect(focused ? 1.12 : 1.0)
                .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 8, y: 3)
                .animation(.easeInOut(duration: 0.15), value: focused)
        }
        .buttonStyle(.plain)
        .focused($focused)
    }
}
