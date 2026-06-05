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
            .navigationDestination(item: $selectedAlbum) { album in
                AlbumDetailView(album: album)
            }
        }
        .task {
            await viewModel.load(using: dependencies)
            // Do NOT force focus into the grid here. On tvOS, entering a
            // tab should leave focus on the tab bar so the user can keep
            // navigating tabs; focus descends into the grid only when they
            // press down. Auto-setting focusedAlbumID yanked focus into the
            // content and also disrupted the focus engine when an album was
            // open. focusedAlbumID still tracks the focused card for its
            // styling, it is just driven by the system, not forced here.
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        if viewModel.isLoading {
            // .focusable so the tab always has a focus target while
            // albums load. Without a focusable element tvOS bounces
            // focus out of the tab and reverts to the previous one.
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
