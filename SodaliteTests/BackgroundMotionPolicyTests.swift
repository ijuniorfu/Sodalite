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

    @Test("only the selected iOS tab receives automatic motion")
    func shellTabMode() {
        #expect(
            ShellBackgroundMotionPolicy.mode(isSelected: true) == .automatic
        )
        #expect(
            ShellBackgroundMotionPolicy.mode(isSelected: false) == .static
        )
    }
}
