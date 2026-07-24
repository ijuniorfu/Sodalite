import Foundation
import Testing
@testable import Sodalite

@Suite("Background motion policy")
struct BackgroundMotionPolicyTests {
    @Test("motion requires every gate to be open", arguments: [
        (true, false, false, false, false, true),
        (false, false, false, false, false, false),
        (true, true, false, false, false, false),
        (true, false, true, false, false, false),
        (true, false, false, true, false, false),
        (true, false, false, false, true, false)
    ])
    func gates(
        sceneActive: Bool,
        reduceMotion: Bool,
        lowPower: Bool,
        playerActive: Bool,
        covered: Bool,
        expected: Bool
    ) {
        #expect(BackgroundMotionPolicy.allowsMotion(
            sceneActive: sceneActive,
            reduceMotion: reduceMotion,
            lowPower: lowPower,
            playerActive: playerActive,
            covered: covered
        ) == expected)
    }

    @Test("cover tracking is idempotent")
    @MainActor
    func coverTracking() {
        let monitor = BackgroundVisibilityMonitor()
        let first = UUID()
        let second = UUID()
        monitor.setCover(first, presented: true)
        monitor.setCover(first, presented: true)
        #expect(monitor.isCovered)
        #expect(monitor.coverCount == 1)
        monitor.setCover(second, presented: true)
        #expect(monitor.coverCount == 2)
        monitor.setCover(first, presented: false)
        #expect(monitor.isCovered)
        monitor.setCover(second, presented: false)
        #expect(!monitor.isCovered)
    }

    @Test("only the highest mounted surface depth receives motion")
    @MainActor
    func highestSurfaceDepth() {
        let monitor = BackgroundVisibilityMonitor()
        let rootA = UUID()
        let rootB = UUID()
        let sheet = UUID()

        monitor.setRenderer(rootA, depth: 0)
        monitor.setRenderer(rootB, depth: 0)
        #expect(monitor.permitsMotion(at: 0))

        monitor.setRenderer(sheet, depth: 1)
        #expect(!monitor.permitsMotion(at: 0))
        #expect(monitor.permitsMotion(at: 1))

        monitor.setRenderer(sheet, depth: nil)
        #expect(monitor.permitsMotion(at: 0))
    }

    @Test("renderer registration and removal are idempotent")
    @MainActor
    func rendererRegistrationIsIdempotent() {
        let monitor = BackgroundVisibilityMonitor()
        let token = UUID()

        monitor.setRenderer(token, depth: 2)
        monitor.setRenderer(token, depth: 2)
        #expect(monitor.rendererCount == 1)
        #expect(monitor.highestRendererDepth == 2)

        monitor.setRenderer(token, depth: nil)
        monitor.setRenderer(token, depth: nil)
        #expect(monitor.rendererCount == 0)
        #expect(monitor.highestRendererDepth == nil)
    }

    @Test("hard cover blocks every renderer depth")
    @MainActor
    func hardCoverBlocksRendererLayers() {
        let monitor = BackgroundVisibilityMonitor()
        let renderer = UUID()
        let cover = UUID()

        monitor.setRenderer(renderer, depth: 3)
        #expect(monitor.permitsMotion(at: 3))
        monitor.setCover(cover, presented: true)
        #expect(!monitor.permitsMotion(at: 3))
        monitor.setCover(cover, presented: false)
        #expect(monitor.permitsMotion(at: 3))
    }
}
