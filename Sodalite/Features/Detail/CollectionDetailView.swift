import SwiftUI

struct CollectionDetailView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass
    @State private var viewModel: DetailViewModel?
    @State private var selectedItem: JellyfinItem?
    @State private var showPlayer = false
    @State private var playItem: JellyfinItem?
    @State private var playQueue: [JellyfinItem] = []

    let item: JellyfinItem

    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var isPhonePortrait: Bool {
        #if os(iOS)
        hSizeClass == .compact && vSizeClass != .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if let vm = viewModel {
                contentView(vm: vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Full-bleed only on iPad/tvOS; iPhone (portrait AND landscape) respects the safe area so
        // content never lands under the Dynamic Island. The backdrop keeps its own .ignoresSafeArea().
        .ignoresSafeArea(when: hSizeClass != .compact && vSizeClass != .compact)
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
                    // loadFullDetail loads collection items internally for .boxSet; a separate loadCollectionItems would be a redundant round trip.
                    await viewModel?.loadFullDetail()
                }
            }
        }
    }

    private func contentView(vm: DetailViewModel) -> some View {
        ZStack {
            DetailBackdrop(
                imageURL: vm.backdropURL(for: vm.item),
                posterFallbackURL: vm.heroPosterURL(for: vm.item)
            )
            .ignoresSafeArea()

            DetailContentOverlay(primary: {
                // Glass panel + action buttons as the bottom-aligned first-page block, matching movie/series detail (Sodalite#15 round 6).
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

                if !vm.collectionItems.isEmpty {
                    collectionList(vm: vm)
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

            if !vm.collectionItems.isEmpty {
                Text("detail.collection.itemCount \(vm.collectionItems.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(isPhonePortrait ? 16 : 30)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
    }

    /// Button row directly below the glass panel, outside the plate,
    /// matching the movie and series detail views.
    private func actionButtonRow(vm: DetailViewModel) -> some View {
        Group {
            if isPhonePortrait {
                VStack(spacing: 12) {
                    primaryActionButton(vm: vm)
                        .frame(maxWidth: .infinity)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { secondaryActionButtons(vm: vm) }
                            .collapsesActionButtonLabel()
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) { secondaryActionButtons(vm: vm) }
                                .collapsesActionButtonLabel()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 16) {
                    primaryActionButton(vm: vm)
                    secondaryActionButtons(vm: vm)
                }
                .collapsesActionButtonLabel()
                .compactScrollableRow(hSizeClass)
            }
        }
    }

    private func primaryActionButton(vm: DetailViewModel) -> some View {
        GlassActionButton(
            title: "detail.play",
            systemImage: "play.fill",
            isProminent: true,
            action: {
                if let first = vm.collectionItems.first {
                    selectedItem = first
                }
            }
        )
    }

    @ViewBuilder
    private func secondaryActionButtons(vm: DetailViewModel) -> some View {
        GlassActionButton(
            title: "action.shuffle",
            systemImage: "shuffle",
            action: {
                // Members already loaded; shuffle client-side, filtered to playable leaf types so a nested series can't seed an unplayable queue entry.
                let queue = vm.collectionItems
                    .filter { $0.type == .movie || $0.type == .episode }
                    .shuffled()
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

    // MARK: - Collection Items (vertical list)

    private func collectionList(vm: DetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("detail.collection.items")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, metrics.rowInset)

            VStack(spacing: 12) {
                ForEach(vm.collectionItems) { movie in
                    CollectionItemRow(
                        item: movie,
                        imageURL: dependencies.jellyfinImageService.posterURL(for: movie),
                        onSelect: { selectedItem = movie }
                    )
                }
            }
            .padding(.horizontal, metrics.rowInset)
        }
    }
}

// MARK: - Collection Item Row

struct CollectionItemRow: View {
    let item: JellyfinItem
    let imageURL: URL?
    let onSelect: () -> Void

    var body: some View {
        Button { onSelect() } label: {
            HStack(spacing: 20) {
                AsyncCachedImage(url: imageURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.Theme.surface)
                }
                .frame(width: 80, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    HStack(spacing: 10) {
                        if let year = item.productionYear {
                            Text(String(year))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let runtime = item.runTimeTicks {
                            Text(runtime.ticksToDisplay)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let score = item.communityRating {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption2)
                                Text(String(format: "%.1f", score))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // RT critic score, fresh/rotten split at 60; only when the server delivers CriticRating.
                        if let critic = item.criticRating {
                            HStack(spacing: 3) {
                                Image(critic >= 60 ? "RTFresh" : "RTRotten")
                                    .resizable()
                                    .renderingMode(.original)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 16)
                                Text(verbatim: "\(Int(critic)) %")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let overview = item.overview {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if item.userData?.played == true {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let pct = item.userData?.playedPercentage, pct > 0 {
                    Text("\(Int(pct))%")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            .padding(16)
        }
        .buttonStyle(CollectionRowButtonStyle())
    }
}

struct CollectionRowButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(rowBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }

    // iOS has no focus engine, so the faint white fill is nearly invisible over a bright poster
    // backdrop; use a glass material for readability (matching the detail bubbles). tvOS keeps the
    // focus-driven white fill.
    @ViewBuilder
    private var rowBackground: some View {
        #if os(iOS)
        RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
        #else
        RoundedRectangle(cornerRadius: 12)
            .fill(isFocused ? .white.opacity(0.12) : .white.opacity(0.05))
        #endif
    }
}
