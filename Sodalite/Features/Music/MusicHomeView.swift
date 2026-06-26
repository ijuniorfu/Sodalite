import SwiftUI

@Observable @MainActor final class MusicHomeViewModel {
    private(set) var albums: [JellyfinItem] = []
    private(set) var isLoading = false

    func load(using dependencies: DependencyContainer) async {
        guard let userID = dependencies.activeUserID else { return }
        isLoading = true
        albums = (try? await dependencies.jellyfinMusicService.getAlbums(userID: userID)) ?? []
        isLoading = false
    }
}

struct MusicHomeView: View {
    @Environment(\.dependencies) private var dependencies
    @State private var viewModel = MusicHomeViewModel()
    @State private var selectedAlbum: JellyfinItem?
    @FocusState private var focusedAlbumID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if dependencies.musicPlaybackCoordinator.currentItem != nil {
                        NowPlayingCard()
                            .padding(.horizontal, 60)
                            .padding(.top, 40)
                            .animation(.spring(response: 0.35, dampingFraction: 0.85),
                                       value: dependencies.musicPlaybackCoordinator.currentItem?.id)
                    }
                    gridContent
                }
            }
            .navigationBarHidden(true)
            // Full-screen cover (over the tab bar) instead of a push: the bar is never hidden/removed, so it is never re-templated gray on return (tvOS 26). See detailCover.
            .detailCover(item: $selectedAlbum) { album in
                AlbumDetailView(album: album)
            }
        }
        .task {
            await viewModel.load(using: dependencies)
            // Do NOT force focus into the grid: entering a tab should leave focus on the tab bar
            // (descends only on press-down). Auto-setting focusedAlbumID yanked focus into content and
            // disrupted the engine when an album was open; it still tracks the focused card for styling, system-driven.
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        if viewModel.isLoading {
            // .focusable so the tab keeps a focus target while loading; without one tvOS bounces focus to the previous tab.
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 400)
                .focusable()
        } else if viewModel.albums.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No albums found")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 400)
            .focusable()
        } else {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 220), spacing: 40)
            ], spacing: 50) {
                ForEach(viewModel.albums) { album in
                    Button {
                        selectedAlbum = album
                    } label: {
                        MediaCard(
                            item: album,
                            imageURL: dependencies.jellyfinImageService.posterURL(for: album),
                            style: .square,
                            isFocused: focusedAlbumID == album.id
                        )
                    }
                    .buttonStyle(GridCardButtonStyle())
                    .focused($focusedAlbumID, equals: album.id)
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
        }
    }
}
