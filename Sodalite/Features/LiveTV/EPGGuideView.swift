import SwiftUI

/// SwiftUI wrapper for the EPG guide. The grid itself is a UIKit
/// `UICollectionView` with a custom layout (see `EPGCollectionContainer`),
/// which gives a true 2D-scrollable time grid with a pinned channel column
/// and time header plus cell reuse, the things SwiftUI cannot do performantly
/// for a large guide. This view owns the loading / error states and the
/// program info popover.
/// Bundles the tapped channel + program so the info sheet receives both
/// atomically. Two separate `@State` values race: `.sheet(item:)` presents as
/// soon as the program is set, but the channel can still read nil in the
/// content closure on the first tap, leaving the sheet empty.
private struct EPGSelection: Identifiable {
    let channel: JellyfinChannel
    let program: JellyfinProgram
    var id: String { "\(channel.id)-\(program.id)" }
}

struct EPGGuideView: View {
    @State private var model: EPGGuideViewModel
    @Environment(\.dependencies) private var dependencies
    @State private var selection: EPGSelection?
    var onWatchLive: ((LivePlaybackContext) -> Void)?
    var isActive: Bool = true

    init(model: EPGGuideViewModel,
         onWatchLive: ((LivePlaybackContext) -> Void)? = nil,
         isActive: Bool = true) {
        _model = State(initialValue: model)
        self.onWatchLive = onWatchLive
        self.isActive = isActive
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
                    isActive: isActive,
                    logoURLProvider: { channel in
                        dependencies.jellyfinImageService.imageURL(
                            itemID: channel.id, imageType: .primary,
                            tag: channel.primaryImageTag, maxHeight: 64)
                    },
                    onSelect: { channel, program in
                        selection = EPGSelection(channel: channel, program: program)
                    }
                )
                // Fill width / bottom, but keep the top safe area so the grid
                // starts below the tab bar (the time header pins to the top of
                // this area, not over the tab bar).
                .ignoresSafeArea(edges: [.horizontal, .bottom])
            }
        }
        .task { await model.loadInitialChannels() }
        .sheet(item: $selection) { sel in
            ProgramInfoPopover(
                program: sel.program, channel: sel.channel, tint: tint,
                onWatchLive: onWatchLive,
                channelIsFavorite: model.isFavorite(sel.channel.id),
                onToggleFavorite: { model.toggleFavorite(channelID: sel.channel.id) },
                hasTimer: model.effectiveTimerState(for: sel.program).timerId != nil,
                hasSeriesTimer: model.effectiveTimerState(for: sel.program).seriesTimerId != nil,
                onToggleRecord: { model.toggleRecord(program: sel.program) },
                onToggleSeriesRecord: { model.toggleSeriesRecord(program: sel.program) })
            // Same alert as below, attached INSIDE the sheet: SwiftUI
            // won't present an alert and a sheet from the same node at
            // once, so a fast server failure on a record toggle (fired
            // from this sheet) was silently dropped while the popover
            // stayed up with its optimistically flipped button.
            .alert(
                Text("livetv.recording.error.title"),
                isPresented: Binding(
                    get: { model.recordingError != nil },
                    set: { if !$0 { model.recordingError = nil } }
                )
            ) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text(model.recordingError ?? "")
            }
        }
        // Gated on `selection == nil`: while the popover sheet is up,
        // its inner copy above owns the presentation. Without the gate
        // both alerts observe the same error and SwiftUI logs a
        // double-present, leaving one of them undismissable.
        .alert(
            Text("livetv.recording.error.title"),
            isPresented: Binding(
                get: { selection == nil && model.recordingError != nil },
                set: { if !$0 { model.recordingError = nil } }
            )
        ) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(model.recordingError ?? "")
        }
    }
}
