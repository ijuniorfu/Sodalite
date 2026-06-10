import SwiftUI

struct LiveTVTabView: View {
    @Environment(\.dependencies) private var dependencies
    // Late-bound once the active user is known, then kept stable across
    // re-renders (matches MusicHomeView's vm lifecycle). Building it as an
    // inline expression would hand State a fresh throwaway vm each render.
    @State private var model: EPGGuideViewModel?
    @State private var recordingsModel: RecordingsViewModel?
    @State private var liveContext: LivePlaybackContext?
    @State private var isPlayerPresented = false
    @State private var section: LiveTVSection = .guide

    private enum LiveTVSection { case guide, recordings }

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

    /// Two focusable pills per the app convention (raw focusable +
    /// stableTap, tinted focus fill; default tvOS segmented controls
    /// fight the EPG's custom focus handling).
    private var sectionPicker: some View {
        HStack(spacing: 16) {
            sectionPill(title: "livetv.segment.guide", value: .guide)
            sectionPill(title: "livetv.segment.recordings", value: .recordings)
            Spacer()
        }
        .padding(.horizontal, 80)
    }

    private func sectionPill(title: LocalizedStringKey, value: LiveTVSection) -> some View {
        SectionPill(title: title, isActive: section == value, tint: tint) {
            section = value
        }
    }
}

private struct SectionPill: View {
    let title: LocalizedStringKey
    let isActive: Bool
    let tint: Color
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(focused ? Color.black : (isActive ? .white : .white.opacity(0.6)))
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(
                    focused ? AnyShapeStyle(tint)
                            : AnyShapeStyle(Color.white.opacity(isActive ? 0.18 : 0.08)))
            )
            .focusable()
            .focused($focused)
            .scaleEffect(focused ? 1.06 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: focused)
            .stableTap(isFocused: focused) { action() }
    }
}
