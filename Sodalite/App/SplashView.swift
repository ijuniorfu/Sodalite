import SwiftUI

/// Brand splash shown while AppRouter restores the session. Logo fades + grows 80%→100% over appearDuration, holds, fades out; minimum on-screen time is SplashView.minimumDisplayDuration (1.2s, enforced in AppRouter) so it never blinks past on a fast restore. Supporters get the crowned Premium variant.
struct SplashView: View {

    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

    private let appearDuration: Double = 0.6

    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 16) {
                logo
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 280, height: 280)
                    .scaleEffect(hasAppeared ? 1.0 : 0.8)
                    .opacity(hasAppeared ? 1.0 : 0.0)

                if appState.isCloudSyncProbing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("cloudSync.launch.loading", bundle: .main)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: appearDuration)) {
                hasAppeared = true
            }
        }
    }

    @ViewBuilder
    private var logo: some View {
        if dependencies.storeKitService.isSupporter {
            Image("PremiumLogo_Hero")
                .resizable()
        } else {
            Image("Logo")
                .resizable()
        }
    }

    static let minimumDisplayDuration: Double = 1.2
}
