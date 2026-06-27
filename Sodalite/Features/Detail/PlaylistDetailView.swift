import SwiftUI

struct PlaylistDetailView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var viewModel: DetailViewModel?
    @State private var selectedItem: JellyfinItem?
    @State private var showPlayer = false
    @State private var playItem: JellyfinItem?
    @State private var playQueue: [JellyfinItem] = []

    let item: JellyfinItem

    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    var body: some View {
        Group {
            if let vm = viewModel {
                contentView(vm: vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .overlay {
            if let userID = appState.activeUser?.id {
                PlayerLauncher(
                    isPresented: $showPlayer,
                    item: showPlayer ? playItem : nil,
                    startFromBeginning: true,
                    playbackService: dependencies.jellyfinPlaybackService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    cachedPlaybackInfo: nil,
                    preferredMediaSourceID: nil,
                    playQueue: playQueue,
                    tintColor: dependencies.appearancePreferences.effectiveTint(
                        isSupporter: dependencies.storeKitService.isSupporter
                    )
                )
                .allowsHitTesting(false)
            }
        }
        .onChange(of: appState.requestPlayerDismissal) { _, _ in
            if showPlayer { showPlayer = false }
        }
        .navigationDestination(item: $selectedItem) { item in
            DetailRouterView(item: item)
        }
        .onAppear {
            if viewModel == nil, let userID = appState.activeUser?.id {
                viewModel = DetailViewModel(
                    item: item,
                    itemService: dependencies.jellyfinItemService,
                    imageService: dependencies.jellyfinImageService,
                    userID: userID,
                    playbackService: dependencies.jellyfinPlaybackService
                )
                Task {
                    await viewModel?.loadFullDetail()
                }
            }
        }
    }

    /// Playlist members restricted to playable video leaves; the list, count, and both play queues all read this so what's shown is exactly what Play/Shuffle enqueues.
    private func videoItems(_ vm: DetailViewModel) -> [JellyfinItem] {
        vm.collectionItems.filter { $0.type == .movie || $0.type == .episode }
    }

    private func contentView(vm: DetailViewModel) -> some View {
        ZStack {
            DetailBackdrop(
                imageURL: vm.backdropURL(for: vm.item),
                posterFallbackURL: vm.posterURL(for: vm.item)
            )

            DetailContentOverlay(primary: {
                VStack(alignment: .leading, spacing: 24) {
                    glassPanel(vm: vm)
                    actionButtonRow(vm: vm)
                }
                .padding(.horizontal, metrics.rowInset)
            }) {
                if let overview = vm.item.overview, !overview.isEmpty {
                    ExpandableTextBox(text: overview)
                        .padding(.horizontal, metrics.rowInset)
                }

                if !videoItems(vm).isEmpty {
                    playlistList(vm: vm)
                }
            }
        }
    }

    // MARK: - Glass Panel

    private func glassPanel(vm: DetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(vm.item.name)
                .font(.largeTitle)
                .fontWeight(.bold)

            let count = videoItems(vm).count
            if count > 0 {
                Text("detail.collection.itemCount \(count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
    }

    /// Play starts direct sequential playback of the ordered queue, unlike
    /// CollectionDetailView whose Play navigates to the first item's detail.
    private func actionButtonRow(vm: DetailViewModel) -> some View {
        HStack(spacing: 16) {
            GlassActionButton(
                title: "detail.play",
                systemImage: "play.fill",
                isProminent: true,
                action: {
                    let queue = videoItems(vm)
                    guard let first = queue.first else { return }
                    playItem = first
                    playQueue = queue
                    showPlayer = true
                }
            )

            GlassActionButton(
                title: "action.shuffle",
                systemImage: "shuffle",
                action: {
                    let queue = videoItems(vm).shuffled()
                    guard let first = queue.first else { return }
                    playItem = first
                    playQueue = queue
                    showPlayer = true
                }
            )

            GlassActionButton(
                title: vm.isFavorite ? "detail.unfavorite" : "detail.favorite",
                systemImage: vm.isFavorite ? "heart.fill" : "heart",
                action: { Task { await vm.toggleFavorite() } }
            )
        }
        .collapsesActionButtonLabel()
        .compactScrollableRow(hSizeClass)
    }

    // MARK: - Playlist Items (vertical list)

    private func playlistList(vm: DetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("detail.collection.items")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, metrics.rowInset)

            VStack(spacing: 12) {
                ForEach(videoItems(vm)) { media in
                    CollectionItemRow(
                        item: media,
                        imageURL: dependencies.jellyfinImageService.posterURL(for: media),
                        onSelect: { selectedItem = media }
                    )
                }
            }
            .padding(.horizontal, metrics.rowInset)
        }
    }
}
