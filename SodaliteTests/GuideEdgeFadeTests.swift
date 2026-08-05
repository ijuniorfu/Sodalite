import Testing
import Foundation
import CoreGraphics
@testable import Sodalite

/// The row the bottom edge cuts through fades out instead of ending in a hard chop. The first
/// attempt was a gradient mask on the controller's view, which was invisible on the device: the
/// guide ignores the bottom safe area, so where that ramp landed on screen was not knowable from
/// the controller. This is the geometry that is knowable, so it is worth pinning.
@MainActor
struct GuideEdgeFadeTests {

    private func row(y: CGFloat, height: CGFloat = 100) -> CGRect {
        CGRect(x: 0, y: y, width: 1600, height: height)
    }

    @Test("a fully visible row is untouched")
    func fullyVisible() {
        #expect(GuideGridViewController.edgeAlpha(for: row(y: 0), visibleBottom: 600) == 1)
        #expect(GuideGridViewController.edgeAlpha(for: row(y: 500), visibleBottom: 600) == 1)
    }

    @Test("a row sitting exactly on the edge is not dimmed for nothing")
    func flushWithTheEdge() {
        #expect(GuideGridViewController.edgeAlpha(for: row(y: 500), visibleBottom: 600) == 1)
    }

    @Test("a half-cut row is dimmed")
    func halfCut() {
        let alpha = GuideGridViewController.edgeAlpha(for: row(y: 550), visibleBottom: 600)
        #expect(alpha > 0.6 && alpha < 0.9)
    }

    @Test("a row barely peeking in is nearly gone")
    func barelyVisible() {
        let alpha = GuideGridViewController.edgeAlpha(for: row(y: 595), visibleBottom: 600)
        #expect(alpha < 0.15)
    }

    @Test("a row entirely below the edge is fully transparent, never negative")
    func fullyBelow() {
        #expect(GuideGridViewController.edgeAlpha(for: row(y: 700), visibleBottom: 600) == 0)
    }

    @Test("a zero-height frame does not divide by zero")
    func degenerateFrame() {
        #expect(GuideGridViewController.edgeAlpha(for: row(y: 700, height: 0),
                                                 visibleBottom: 600) == 1)
    }
}
