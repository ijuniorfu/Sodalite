import SwiftUI

// MARK: - View Model

@Observable @MainActor final class AlbumDetailViewModel {
    private(set) var songs: [JellyfinItem] = []
    private(set) var isLoading = false

    func load(album: JellyfinItem, using dependencies: DependencyContainer) async {
        guard let userID = dependencies.activeUserID else { return }
        isLoading = true
        songs = (try? await dependencies.jellyfinMusicService.getSongs(
            userID: userID,
            albumID: album.id
        )) ?? []
        isLoading = false
    }
}

// MARK: - View

struct AlbumDetailView: View {
    let album: JellyfinItem

    @Environment(\.dependencies) private var dependencies
    @State private var viewModel = AlbumDetailViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                albumHeader
                tracklist
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
        }
        // Hide the top tab bar while inside an album (music tab), matching
        // movie/series/catalog detail. Playlists reached via DetailRouterView
        // already hide it; this covers the music tab's album destination.
        .toolbar(.hidden, for: .tabBar)
        .task {
            await viewModel.load(album: album, using: dependencies)
        }
    }

    // MARK: Header

    private var albumHeader: some View {
        HStack(alignment: .top, spacing: 48) {
            coverImage

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(album.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    if let artist = album.albumArtist, !artist.isEmpty {
                        Text(artist)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let year = album.productionYear {
                        Text(String(year))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if viewModel.isLoading {
                    ProgressView()
                        .padding(.top, 8)
                } else {
                    actionButtons
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var coverImage: some View {
        AsyncCachedImage(url: dependencies.jellyfinImageService.posterURL(for: album)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                )
        }
        .frame(width: 340, height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            GlassActionButton(
                title: "album.detail.play",
                systemImage: "play.fill",
                isProminent: true
            ) {
                dependencies.musicPlaybackCoordinator.play(
                    queue: viewModel.songs,
                    startAt: 0,
                    contextTitle: album.name
                )
            }

            GlassActionButton(
                title: "album.detail.shuffle",
                systemImage: "shuffle"
            ) {
                dependencies.musicPlaybackCoordinator.play(
                    queue: viewModel.songs.shuffled(),
                    startAt: 0,
                    contextTitle: album.name
                )
            }
        }
        .collapsesActionButtonLabel()
    }

    // MARK: Tracklist

    @ViewBuilder
    private var tracklist: some View {
        if !viewModel.isLoading && !viewModel.songs.isEmpty {
            let coordinator = dependencies.musicPlaybackCoordinator
            VStack(spacing: 8) {
                ForEach(Array(viewModel.songs.enumerated()), id: \.element.id) { index, song in
                    TrackRow(
                        song: song,
                        isCurrent: coordinator.currentItem?.id == song.id,
                        isPlaying: coordinator.isPlaying,
                        onSelect: {
                            // Tapping the track that is already playing just
                            // opens the player; don't restart it from the top.
                            if coordinator.currentItem?.id == song.id {
                                coordinator.requestNowPlayingPresentation()
                            } else {
                                coordinator.play(queue: viewModel.songs, startAt: index, contextTitle: album.name)
                            }
                        }
                    )
                }
            }
        }
    }
}

// MARK: - Track Row

private struct TrackRow: View {
    let song: JellyfinItem
    let isCurrent: Bool
    let isPlaying: Bool
    let onSelect: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            // Leading: an animated now-playing indicator for the current
            // track, otherwise the track number.
            Group {
                if isCurrent {
                    NowPlayingWaveIcon(isPlaying: isPlaying, font: .body)
                } else {
                    Text(song.indexNumber.map { String($0) } ?? "")
                        .font(.body)
                        .foregroundStyle(focused ? .white : Color.secondary)
                        .monospacedDigit()
                }
            }
            .frame(width: 32, alignment: .center)

            Text(song.name)
                .font(.body)
                .fontWeight(isCurrent ? .semibold : .medium)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let ticks = song.runTimeTicks,
               let formatted = ResumeTimeFormatter.format(ticks: ticks) {
                Text(formatted)
                    .font(.caption)
                    .foregroundStyle(focused ? Color.white.opacity(0.85) : Color.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(focused ? Color.white.opacity(0.15) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.015 : 1.0)
        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 14, y: 6)
        .focusable(true)
        .focused($focused)
        .animation(.easeInOut(duration: 0.15), value: focused)
        .stableTap(isFocused: focused) {
            onSelect()
        }
    }

    /// `.tint` and `Color` are different shape-style types, so erase to
    /// AnyShapeStyle to pick between them in one expression.
    private var titleColor: AnyShapeStyle {
        if isCurrent { return AnyShapeStyle(.tint) }
        return AnyShapeStyle(focused ? Color.white : Color.primary)
    }
}
