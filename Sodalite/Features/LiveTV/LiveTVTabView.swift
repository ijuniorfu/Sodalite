import SwiftUI

struct LiveTVTabView: View {
    @Environment(\.dependencies) private var dependencies
    // Late-bound once the active user is known, then kept stable across
    // re-renders (matches MusicHomeView's vm lifecycle). Building it as an
    // inline expression would hand State a fresh throwaway vm each render.
    @State private var model: EPGGuideViewModel?
    @State private var liveContext: LivePlaybackContext?
    @State private var isPlayerPresented = false

    var body: some View {
        Group {
            if let model {
                EPGGuideView(
                    model: model,
                    onWatchLive: { context in
                        liveContext = context
                        // Let the info sheet finish dismissing before the
                        // full-screen player modal presents; presenting while
                        // the sheet is still animating out silently no-ops.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            isPlayerPresented = true
                        }
                    }
                )
            } else {
                ProgressView()
            }
        }
        .task {
            guard model == nil, let userID = dependencies.activeUserID else { return }
            model = EPGGuideViewModel(
                service: dependencies.jellyfinLiveTvService, userID: userID)
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
                    tintColor: dependencies.appearancePreferences.effectiveTint(
                        isSupporter: dependencies.storeKitService.isSupporter
                    )
                )
                .allowsHitTesting(false)
            }
        }
    }
}
