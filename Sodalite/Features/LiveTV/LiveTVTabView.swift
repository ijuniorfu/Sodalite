import SwiftUI

struct LiveTVTabView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    // Late-bound once the active user is known, then stable across re-renders (matches MusicHomeView);
    // an inline expression would hand State a fresh throwaway vm each render.
    @State private var model: EPGGuideViewModel?
    @State private var recordingsModel: RecordingsViewModel?
    @State private var programsModel: LiveProgramsViewModel?
    @State private var liveContext: LivePlaybackContext?
    @State private var isPlayerPresented = false
    @State private var section: LiveTVSection = .overview

    private enum LiveTVSection { case overview, guide, recordings }

    private var tint: Color {
        dependencies.appearancePreferences.effectiveTint(
            isSupporter: dependencies.storeKitService.isSupporter) ?? Color.accentColor
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionPicker
                .padding(.top, 20)
            ZStack {
                Group {
                    if let model {
                        EPGGuideView(
                            model: model,
                            onWatchLive: { context in
                                liveContext = context
                                // Launcher polls for the info sheet to finish dismissing before
                                // presenting the player, so flipping this immediately is safe.
                                isPlayerPresented = true
                            },
                            isActive: section == .guide
                        )
                    } else {
                        ProgressView()
                    }
                }
                // Keep the UIKit grid alive across the toggle (scroll + focus state survive); just hide it.
                .opacity(section == .guide ? 1 : 0)
                .allowsHitTesting(section == .guide)

                if section == .overview, let programsModel, let model {
                    LiveProgramsView(
                        model: programsModel,
                        guideModel: model,
                        tint: tint,
                        onWatchLive: { context in
                            liveContext = context
                            isPlayerPresented = true
                        })
                }

                if section == .recordings, let recordingsModel {
                    RecordingsView(model: recordingsModel, tint: tint)
                }
            }
        }
        .task {
            guard model == nil, let userID = dependencies.activeUserID else { return }
            model = EPGGuideViewModel(
                service: dependencies.jellyfinLiveTvService, userID: userID,
                metrics: EPGMetrics.current(hSizeClass))
            recordingsModel = RecordingsViewModel(
                liveTvService: dependencies.jellyfinLiveTvService,
                itemService: dependencies.jellyfinItemService,
                userID: userID)
            programsModel = LiveProgramsViewModel(
                service: dependencies.jellyfinLiveTvService, userID: userID)
        }
        .onChange(of: section) { _, newValue in
            // Recordings can cancel timers/rules the overlay doesn't know; resync on the way back so
            // dots/actions match the server. Übersicht shares the model (and is the default landing), so resync it too.
            guard newValue == .guide || newValue == .overview, let model else { return }
            Task { await model.syncTimersWithServer() }
        }
        .overlay {
            // Guard userID at the call site (mirrors MovieDetailView) so the live player never launches blank.
            if let userID = dependencies.activeUserID {
                LivePlayerLauncher(
                    isPresented: $isPlayerPresented,
                    context: isPlayerPresented ? liveContext : nil,
                    playbackService: dependencies.jellyfinPlaybackService,
                    liveTvService: dependencies.jellyfinLiveTvService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    tintColor: tint
                )
                .allowsHitTesting(false)
            }
        }
    }

    /// Native segmented control, matching the Catalog tab's bar for consistency. It replaced custom
    /// pills that existed because a segmented control was suspected of fighting the EPG's custom focus
    /// handling; if focus between this picker and the UIKit grid misbehaves, revert this commit
    /// (pill implementation lives in its parent) instead of patching around it.
    private var sectionPicker: some View {
        Picker("", selection: $section) {
            Text("livetv.segment.overview").tag(LiveTVSection.overview)
            Text("livetv.segment.guide").tag(LiveTVSection.guide)
            Text("livetv.segment.recordings").tag(LiveTVSection.recordings)
        }
        .pickerStyle(.segmented)
        // tvOS/iPad keep the wide inset; compact uses a phone-scale margin so the control fits ~393pt.
        .padding(.horizontal, hSizeClass == .compact ? 16 : 80)
    }
}
