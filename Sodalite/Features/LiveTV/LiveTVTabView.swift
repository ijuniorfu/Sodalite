import SwiftUI

struct LiveTVTabView: View {
    @Environment(\.dependencies) private var dependencies
    // Late-bound once the active user is known, then kept stable across
    // re-renders (matches MusicHomeView's vm lifecycle). Building it as an
    // inline expression would hand State a fresh throwaway vm each render.
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
                                // The launcher polls for the info sheet to finish
                                // dismissing before presenting the player, so we can
                                // flip this immediately.
                                isPlayerPresented = true
                            },
                            isActive: section == .guide
                        )
                    } else {
                        ProgressView()
                    }
                }
                // Keep the UIKit grid alive across the toggle so scroll
                // and focus state survive; just hide it.
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
                service: dependencies.jellyfinLiveTvService, userID: userID)
            recordingsModel = RecordingsViewModel(
                liveTvService: dependencies.jellyfinLiveTvService,
                itemService: dependencies.jellyfinItemService,
                userID: userID)
            programsModel = LiveProgramsViewModel(
                service: dependencies.jellyfinLiveTvService, userID: userID)
        }
        .onChange(of: section) { _, newValue in
            // The Recordings segment can cancel timers/series rules the
            // guide's optimistic overlay knows nothing about; resync on
            // the way back so dots and popover actions match the server.
            // Übersicht shares the same model for record state, so it needs
            // the resync too (and it is the default landing section).
            guard newValue == .guide || newValue == .overview, let model else { return }
            Task { await model.syncTimersWithServer() }
        }
        .overlay {
            // Guard userID at the call site (mirrors MovieDetailView's
            // PlayerLauncher placement) so the live player never launches
            // with a blank user id.
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

    /// Native segmented control, same look as the Catalog tab's
    /// Entdecken / Meine Anfragen / Alle Anfragen bar (Vincent wants
    /// the two tabs visually consistent). The original custom pills
    /// existed because a segmented control was suspected of fighting
    /// the EPG's custom focus handling; if focus between this picker
    /// and the UIKit guide grid misbehaves, that suspicion was right,
    /// revert this commit (the pill implementation lives in its
    /// parent) instead of patching around it.
    private var sectionPicker: some View {
        Picker("", selection: $section) {
            Text("livetv.segment.overview").tag(LiveTVSection.overview)
            Text("livetv.segment.guide").tag(LiveTVSection.guide)
            Text("livetv.segment.recordings").tag(LiveTVSection.recordings)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 80)
    }
}
