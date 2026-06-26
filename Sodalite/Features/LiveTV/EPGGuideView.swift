import SwiftUI

/// Bundles tapped channel + program so the info sheet gets both atomically: with two separate
/// `@State`s, `.sheet(item:)` presents as soon as program is set but the channel can read nil in the
/// content closure on the first tap, leaving the sheet empty. (The grid is a UIKit
/// `UICollectionView`, see `EPGCollectionContainer`; this view owns loading/error + the popover.)
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
                // Keep the top safe area so the grid (and its pinned time header) starts below the tab bar.
                .ignoresSafeArea(edges: [.horizontal, .bottom])
            }
        }
        .task { await model.loadInitialChannels() }
        // Full-screen cover, NOT .sheet: a tvOS sheet leaves the tab bar visible behind it and backgrounds it, which tvOS 26 re-templates gray. The cover covers the bar so it is never disturbed (same fix as the detail screens).
        .detailCover(item: $selection) { sel in
            ProgramInfoPopover(
                program: sel.program, channel: sel.channel, tint: tint,
                onWatchLive: onWatchLive,
                channelIsFavorite: model.isFavorite(sel.channel.id),
                onToggleFavorite: { model.toggleFavorite(channelID: sel.channel.id) },
                hasTimer: model.effectiveTimerState(for: sel.program).timerId != nil,
                hasSeriesTimer: model.effectiveTimerState(for: sel.program).seriesTimerId != nil,
                onToggleRecord: { model.toggleRecord(program: sel.program) },
                onToggleSeriesRecord: { model.toggleSeriesRecord(program: sel.program) })
            // Alert attached INSIDE the sheet: SwiftUI won't present an alert and a sheet from the
            // same node at once, so a fast record-toggle failure was dropped while the popover
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
        // Gated on `selection == nil`: while the sheet is up its inner alert owns presentation;
        // without the gate both observe the same error and SwiftUI double-presents (one undismissable).
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
