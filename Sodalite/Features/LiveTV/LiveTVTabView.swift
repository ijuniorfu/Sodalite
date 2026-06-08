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
                        isPlayerPresented = true
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
        // TODO(Task 14): present LivePlayerLauncher here once it exists.
        // For now the Watch Live tap records the context + flag but does
        // not yet present a player.
    }
}
