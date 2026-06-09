import SwiftUI

/// SwiftUI wrapper for the EPG guide. The grid itself is a UIKit
/// `UICollectionView` with a custom layout (see `EPGCollectionContainer`),
/// which gives a true 2D-scrollable time grid with a pinned channel column
/// and time header plus cell reuse, the things SwiftUI cannot do performantly
/// for a large guide. This view owns the loading / error states and the
/// program info popover.
struct EPGGuideView: View {
    @State private var model: EPGGuideViewModel
    @Environment(\.dependencies) private var dependencies
    @State private var selectedProgram: JellyfinProgram?
    @State private var selectedChannel: JellyfinChannel?
    var onWatchLive: ((LivePlaybackContext) -> Void)?

    init(model: EPGGuideViewModel, onWatchLive: ((LivePlaybackContext) -> Void)? = nil) {
        _model = State(initialValue: model)
        self.onWatchLive = onWatchLive
    }

    private var tint: Color {
        dependencies.appearancePreferences.effectiveTint(
            isSupporter: dependencies.storeKitService.isSupporter
        ) ?? Color.accentColor
    }

    var body: some View {
        Group {
            if model.channels.isEmpty && model.isLoadingChannels {
                ProgressView()
            } else if model.channels.isEmpty, let err = model.loadError {
                ContentUnavailableView(
                    "livetv.loadFailed.title",
                    systemImage: "tv.slash",
                    description: Text(err))
            } else {
                EPGCollectionContainer(
                    model: model,
                    tint: tint,
                    logoURLProvider: { channel in
                        dependencies.jellyfinImageService.imageURL(
                            itemID: channel.id, imageType: .primary,
                            tag: channel.primaryImageTag, maxHeight: 64)
                    },
                    onSelect: { channel, program in
                        selectedChannel = channel
                        selectedProgram = program
                    }
                )
                // Fill width / bottom, but keep the top safe area so the grid
                // starts below the tab bar (the time header pins to the top of
                // this area, not over the tab bar).
                .ignoresSafeArea(edges: [.horizontal, .bottom])
            }
        }
        .task { await model.loadInitialChannels() }
        .sheet(item: $selectedProgram) { program in
            if let channel = selectedChannel {
                ProgramInfoPopover(
                    program: program, channel: channel, tint: tint,
                    onWatchLive: onWatchLive,
                    channelIsFavorite: model.isFavorite(channel.id),
                    onToggleFavorite: { model.toggleFavorite(channelID: channel.id) })
            }
        }
    }
}
