import Testing
import CoreGraphics
import UIKit
import SwiftUI
@testable import Sodalite

/// Sodalite#142: there was no way out of Now Playing on iOS.
///
/// The tier was picked from the horizontal size class alone, and a regular width class does not
/// promise a container the wide column fits in. An iPhone Plus / Max in landscape reports REGULAR
/// with about 420pt of usable height, while the cover, its spacing and the chrome need 638. The page
/// then grew past the screen, the ZStack centred the overflow, and the close button, an overlay on
/// that same stack, left the screen with it. Measured on an iPhone 17 Pro Max simulator: the top-left
/// corner was empty and the cover was cut off at the top.
///
/// So the decision is a measurement now, and this pins it. The iOS numbers are spelled out because
/// the test target builds for tvOS, where `NowPlayingMetrics` answers with the tvOS tier.
struct NowPlayingWideFitTests {

    /// The metrics the iOS regular tier hands the layout.
    private static let iOSMinimum = NowPlayingMetrics.wideMinimumSize(
        coverSide: 360,
        columnWidth: 400,
        spacing: 48,
        hPadding: 40,
        vPadding: 40
    )

    private static func fitsWide(_ container: CGSize, minimum: CGSize) -> Bool {
        container.width >= minimum.width && container.height >= minimum.height
    }

    @Test("The minimum is the sum of the metrics the layout itself uses")
    func minimumIsTheSumOfItsParts() {
        let minimum = Self.iOSMinimum
        #expect(minimum.width == 2 * 40 + 400 + 48 + NowPlayingMetrics.queueMinimumWidth)
        #expect(minimum.height == 2 * 40 + 360 + NowPlayingMetrics.columnSpacing + NowPlayingMetrics.chromeBlockHeight)
    }

    @Test("An iPhone Plus / Max in landscape is too short for the wide column")
    func phoneLandscapeFallsBackToTheStack() {
        // iPhone 17 Pro Max landscape, safe area off both ends: 956x440 becomes about 838x419.
        #expect(Self.fitsWide(CGSize(width: 838, height: 419), minimum: Self.iOSMinimum) == false)
    }

    @Test("An iPad keeps the wide column in both orientations")
    func padKeepsTheWideColumn() {
        // iPad Pro 11", safe area off both ends.
        #expect(Self.fitsWide(CGSize(width: 834, height: 1166), minimum: Self.iOSMinimum))
        #expect(Self.fitsWide(CGSize(width: 1210, height: 790), minimum: Self.iOSMinimum))
    }

    @Test("A narrow iPad window falls back rather than overflowing")
    func narrowPadWindowFallsBackToTheStack() {
        // Half of an 11" landscape is under the queue's own minimum width.
        #expect(Self.fitsWide(CGSize(width: 591, height: 790), minimum: Self.iOSMinimum) == false)
    }

    @Test("The tvOS band clears its own minimum")
    func tvBandFits() {
        #expect(Self.fitsWide(CGSize(width: 1920, height: 1080), minimum: NowPlayingMetrics.wideMinimumSize))
    }
}

/// Sodalite#142, the part the tier fix did not reach: with real cover art loaded, every greedy child
/// of the stacked screen was laid out at about twice the width of an iPhone in portrait.
///
/// The blurred background is a `.fill` image, and a square one offered 430x839 reports 839x839. The
/// screen's ZStack took that width and handed it to the content beside it, so the title block and the
/// scrubber overhung both edges while the fixed-width cover sat correctly in the middle. The
/// placeholder is a flexible shape and never did it, which is why a harness without artwork could not
/// reproduce the report. Hosted here with a square image, measured on the same screen shape.
@MainActor
struct NowPlayingBackdropFillTests {

    private static let screen = CGSize(width: 430, height: 839)
    private static let hPadding: CGFloat = 20

    private final class Frames {
        var backdrop: CGRect = .zero
        var greedy: CGRect = .zero
    }

    /// The stacked screen's shape: an opaque base, the backdrop, and a scroll column with greedy content.
    private struct Harness: View {
        let frames: Frames

        private static let squareCover = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        }

        var body: some View {
            ZStack {
                Color.black

                NowPlayingBackdropFill {
                    Image(uiImage: Self.squareCover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.backdrop = $0 }

                ScrollView {
                    VStack {
                        Color.clear
                            .frame(height: 40)
                            .frame(maxWidth: .infinity)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.greedy = $0 }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, NowPlayingBackdropFillTests.hPadding)
                }
            }
            .frame(width: NowPlayingBackdropFillTests.screen.width, height: NowPlayingBackdropFillTests.screen.height)
            .ignoresSafeArea()
        }
    }

    /// Same hosting as `NowPlayingColumnAlignmentTests`: a scene-built window, then the frame set by hand.
    private func layout() throws -> Frames {
        let frames = Frames()
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene to build a window against")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.screen)
        let controller = UIHostingController(rootView: Harness(frames: frames))
        controller.view.frame = window.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        controller.view.layoutIfNeeded()
        return frames
    }

    @Test("A loaded square cover does not widen the content beside it")
    func greedyContentKeepsTheScreenWidth() throws {
        let frames = try layout()

        #expect(abs(frames.greedy.width - (Self.screen.width - 2 * Self.hPadding)) <= 1)
        #expect(abs(frames.greedy.minX - Self.hPadding) <= 1)
    }

    @Test("The backdrop still covers the whole screen")
    func backdropCoversTheScreen() throws {
        let frames = try layout()

        #expect(abs(frames.backdrop.width - Self.screen.width) <= 1)
        #expect(abs(frames.backdrop.height - Self.screen.height) <= 1)
    }
}
