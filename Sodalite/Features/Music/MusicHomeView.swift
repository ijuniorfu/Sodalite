import SwiftUI

@Observable @MainActor final class MusicHomeViewModel {
    private(set) var albums: [JellyfinItem] = []
    private(set) var isLoading = false
    /// Set only when the fetch threw. `try? ... ?? []` used to collapse every failure into an empty
    /// array, so a 400, a decode mismatch and a genuinely empty music library all rendered the same
    /// "No albums found" screen and left nothing in the diagnostic log either (Sodalite#88). Empty
    /// and failed are not the same state, the rule Home already follows for its rows.
    private(set) var errorMessage: String?

    /// The error screen is for a viewer with nothing else to look at. A reload that fails while a
    /// grid is already up keeps the grid, so a transient hiccup does not empty the tab.
    var displayedError: String? { albums.isEmpty ? errorMessage : nil }

    func load(using dependencies: DependencyContainer) async {
        await load(service: dependencies.jellyfinMusicService, userID: dependencies.activeUserID)
    }

    func load(service: JellyfinMusicServiceProtocol, userID: String?) async {
        guard let userID else {
            LogTap.shared.note("[music] albums: no active user, nothing requested")
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await service.getAlbums(userID: userID)
            albums = fetched
            errorMessage = nil
            LogTap.shared.note("[music] albums: \(fetched.count) returned")
        } catch is CancellationError {
            // A cancelled reload is not an outcome. The next one answers.
        } catch {
            errorMessage = ErrorText.user(for: error)
            LogTap.shared.note("[music] albums failed: \(HTTPDiagnostics.describe(error))")
        }
    }
}

struct MusicHomeView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var viewModel = MusicHomeViewModel()
    @State private var selectedAlbum: JellyfinItem?
    @FocusState private var focusedAlbumID: String?

    var body: some View {
        let metrics = LayoutMetrics.current(hSizeClass)
        ThemeNavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if dependencies.musicPlaybackCoordinator.currentItem != nil {
                        NowPlayingCard()
                            .padding(.horizontal, metrics.gridInset)
                            .padding(.top, hSizeClass == .compact ? 16 : 40)
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
        } else if let error = viewModel.displayedError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(error)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await viewModel.load(using: dependencies) }
                } label: {
                    Text("home.retry")
                        .font(.body)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                }
                .buttonStyle(SettingsTileButtonStyle())
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, minHeight: 400)
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
            let metrics = LayoutMetrics.current(hSizeClass)
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: metrics.gridMinimum), spacing: metrics.gridSpacing)
            ], spacing: gridRowSpacing) {
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
            .padding(.horizontal, metrics.gridInset)
            .padding(.vertical, hSizeClass == .compact ? 24 : 40)
        }
    }

    /// tvOS keeps its 50pt row gap (byte-identical); other tiers track the metrics grid spacing.
    private var gridRowSpacing: CGFloat {
        #if os(tvOS)
        50
        #else
        LayoutMetrics.current(hSizeClass).gridSpacing
        #endif
    }
}
