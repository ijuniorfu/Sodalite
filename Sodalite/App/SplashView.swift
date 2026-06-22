import SwiftUI

/// Brand splash shown while AppRouter restores the session. Logo fades + grows 80%→100% over appearDuration, holds, fades out; minimum on-screen time appearDuration+holdDuration so it never blinks past on a fast restore. Supporters get the crowned Premium variant.
struct SplashView: View {

    @Environment(\.dependencies) private var dependencies

    private let appearDuration: Double = 0.6
    private let holdDuration: Double = 0.6

    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            logo
                .aspectRatio(contentMode: .fit)
                .frame(width: 280, height: 280)
                .scaleEffect(hasAppeared ? 1.0 : 0.8)
                .opacity(hasAppeared ? 1.0 : 0.0)
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
