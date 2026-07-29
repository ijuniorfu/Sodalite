import Testing
import Foundation
import CoreGraphics
import SwiftUI
import AetherEngine
@testable import Sodalite

/// Placement geometry for text cues that ask to be drawn somewhere specific (AetherEngine #233):
/// teletext subtitle pages, WebVTT cue settings, SRT position side data, and ASS `\an` / `\pos`
/// on the fallback path. Mirrors `SubtitleFrameCompositor.blockOrigin` in the engine so the
/// engine's own compositor and this overlay place the same cue in the same spot, translated to
/// SwiftUI's top-down y axis.
@MainActor
struct SubtitlePlacementGeometryTests {

    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 500)
    private let block = CGSize(width: 200, height: 100)
    private let margin: CGFloat = 80

    private func origin(alignment: Int? = nil, position: CGPoint? = nil,
                        in frame: CGRect? = nil,
                        verticalShift: CGFloat = 0,
                        bottomLimit: CGFloat = .infinity) -> CGPoint {
        SubtitleOverlayView.placedOrigin(
            placement: SubtitleTextPlacement(alignment: alignment, position: position),
            blockSize: block,
            in: frame ?? self.frame,
            margin: margin,
            verticalShift: verticalShift,
            bottomLimit: bottomLimit)
    }

    // MARK: - Alignment without an anchor: the block goes to a corner, inset by the margin

    @Test func alignment1PlacesBottomLeft() {
        #expect(origin(alignment: 1) == CGPoint(x: 80, y: 320))
    }

    @Test func alignment3PlacesBottomRight() {
        #expect(origin(alignment: 3) == CGPoint(x: 720, y: 320))
    }

    @Test func alignment5CentresBothAxes() {
        #expect(origin(alignment: 5) == CGPoint(x: 400, y: 200))
    }

    @Test func alignment7PlacesTopLeft() {
        #expect(origin(alignment: 7) == CGPoint(x: 80, y: 80))
    }

    @Test func alignment9PlacesTopRight() {
        #expect(origin(alignment: 9) == CGPoint(x: 720, y: 80))
    }

    /// The ASS default is 2, and it has to land exactly where an unplaced cue lands, otherwise a
    /// track that carries `\an` on some cues and not others makes the text jump between them.
    @Test func missingAlignmentFallsBackToBottomCentre() {
        #expect(origin() == origin(alignment: 2))
        #expect(origin() == CGPoint(x: 400, y: 320))
    }

    @Test func outOfRangeAlignmentFallsBackToBottomCentre() {
        #expect(origin(alignment: 0) == origin(alignment: 2))
        #expect(origin(alignment: 10) == origin(alignment: 2))
        #expect(origin(alignment: -3) == origin(alignment: 2))
    }

    // MARK: - Anchor: the point is where the block hangs, alignment says by which part

    @Test func anchorWithTopAlignmentHangsBlockBelowThePoint() {
        // \an8 + \pos: horizontally centred on the anchor, top edge on it.
        #expect(origin(alignment: 8, position: CGPoint(x: 0.5, y: 0.25)) == CGPoint(x: 400, y: 125))
    }

    @Test func anchorWithBottomAlignmentHangsBlockAboveThePoint() {
        #expect(origin(alignment: 2, position: CGPoint(x: 0.5, y: 0.9)) == CGPoint(x: 400, y: 350))
    }

    @Test func anchorWithMiddleAlignmentCentresBlockOnThePoint() {
        #expect(origin(alignment: 5, position: CGPoint(x: 0.5, y: 0.5)) == CGPoint(x: 400, y: 200))
    }

    @Test func anchorWithLeftAlignmentStartsBlockAtThePoint() {
        #expect(origin(alignment: 1, position: CGPoint(x: 0.2, y: 0.8)) == CGPoint(x: 200, y: 300))
    }

    @Test func anchorIgnoresTheMargin() {
        // A `\pos` is exact; insetting it by the default margin would move an authored sign.
        let atEdge = origin(alignment: 7, position: CGPoint(x: 0, y: 0))
        #expect(atEdge == CGPoint(x: 0, y: 0))
    }

    // MARK: - Frame: cues live in the aspect-fit video band, not the full screen

    @Test func originIsRelativeToTheVideoBand() {
        let band = CGRect(x: 100, y: 50, width: 800, height: 400)
        #expect(origin(alignment: 7, in: band) == CGPoint(x: 180, y: 130))
        #expect(origin(alignment: 3, in: band) == CGPoint(x: 620, y: 270))
    }

    @Test func anchorIsRelativeToTheVideoBand() {
        let band = CGRect(x: 100, y: 50, width: 800, height: 400)
        // Anchor at the band centre: 100 + 0.5*800 = 500, 50 + 0.5*400 = 250.
        #expect(origin(alignment: 5, position: CGPoint(x: 0.5, y: 0.5), in: band)
                == CGPoint(x: 400, y: 200))
    }

    // MARK: - The user's vertical position dial, applied as the same delta bitmap cues get

    @Test func verticalShiftMovesAPlacedCue() {
        #expect(origin(alignment: 2, verticalShift: -50) == CGPoint(x: 400, y: 270))
    }

    @Test func verticalShiftAppliesToAnchoredCuesToo() {
        #expect(origin(alignment: 8, position: CGPoint(x: 0.5, y: 0.25), verticalShift: -25)
                == CGPoint(x: 400, y: 100))
    }

    @Test func verticalShiftDoesNotTouchTheHorizontalAxis() {
        #expect(origin(alignment: 3, verticalShift: -120).x == origin(alignment: 3).x)
    }

    // MARK: - Player chrome: a low cue is lifted clear of it, a high one is left alone

    @Test func bottomLimitLiftsACueThatWouldSitUnderTheControls() {
        #expect(origin(alignment: 2, bottomLimit: 300) == CGPoint(x: 400, y: 200))
    }

    @Test func bottomLimitLeavesAHighCueWhereItIs() {
        #expect(origin(alignment: 8, bottomLimit: 300) == origin(alignment: 8))
    }

    @Test func bottomLimitAppliesAfterTheVerticalShift() {
        // Shift already lifts it to 270, which clears a 400 limit, so the limit must not push
        // it back down.
        #expect(origin(alignment: 2, verticalShift: -50, bottomLimit: 400) == CGPoint(x: 400, y: 270))
    }

    @Test func bottomLimitAppliesToAnchoredCues() {
        #expect(origin(alignment: 2, position: CGPoint(x: 0.5, y: 0.98), bottomLimit: 300)
                == CGPoint(x: 400, y: 200))
    }

    // MARK: - What the view actually applies: a SwiftUI alignment plus an offset
    //
    // The block's size is not known until it lays out, so the view never asks for it: the
    // alignment picks which corner of the block is the reference, and the offset moves that
    // corner to the target. `placedOrigin` with a zero block IS that target, so both forms stay
    // one formula.

    @Test func alignmentMapsTheNumpadOntoSwiftUI() {
        #expect(SubtitleOverlayView.placedAlignment(1) == .bottomLeading)
        #expect(SubtitleOverlayView.placedAlignment(2) == .bottom)
        #expect(SubtitleOverlayView.placedAlignment(3) == .bottomTrailing)
        #expect(SubtitleOverlayView.placedAlignment(4) == .leading)
        #expect(SubtitleOverlayView.placedAlignment(5) == .center)
        #expect(SubtitleOverlayView.placedAlignment(6) == .trailing)
        #expect(SubtitleOverlayView.placedAlignment(7) == .topLeading)
        #expect(SubtitleOverlayView.placedAlignment(8) == .top)
        #expect(SubtitleOverlayView.placedAlignment(9) == .topTrailing)
    }

    @Test func alignmentFallsBackToBottomCentreLikeTheOrigin() {
        #expect(SubtitleOverlayView.placedAlignment(nil) == .bottom)
        #expect(SubtitleOverlayView.placedAlignment(0) == .bottom)
        #expect(SubtitleOverlayView.placedAlignment(42) == .bottom)
    }

    private func offset(alignment: Int? = nil, position: CGPoint? = nil,
                        in frame: CGRect? = nil,
                        container: CGSize = CGSize(width: 1000, height: 500),
                        verticalShift: CGFloat = 0,
                        bottomLimit: CGFloat = .infinity) -> CGSize {
        SubtitleOverlayView.placedOffset(
            placement: SubtitleTextPlacement(alignment: alignment, position: position),
            in: frame ?? self.frame,
            container: container,
            margin: margin,
            verticalShift: verticalShift,
            bottomLimit: bottomLimit)
    }

    /// `\an2` in a container that matches the video band: bottom centre is already where SwiftUI
    /// puts a `.bottom`-aligned view, so only the margin remains.
    @Test func bottomCentreOffsetIsJustTheMargin() {
        #expect(offset(alignment: 2) == CGSize(width: 0, height: -80))
    }

    @Test func topLeftOffsetMovesFromTheTopLeadingCorner() {
        #expect(offset(alignment: 7) == CGSize(width: 80, height: 80))
    }

    @Test func bottomRightOffsetMovesFromTheBottomTrailingCorner() {
        #expect(offset(alignment: 3) == CGSize(width: -80, height: -80))
    }

    @Test func centredOffsetIsZeroInAMatchingContainer() {
        #expect(offset(alignment: 5) == CGSize(width: 0, height: 0))
    }

    /// A letterboxed video band inside a taller container: the offset carries the band's inset,
    /// so the cue sits in the picture rather than against the screen edge.
    @Test func offsetCarriesTheVideoBandInset() {
        let band = CGRect(x: 100, y: 50, width: 800, height: 400)
        // Bottom centre of the band is y = 450 - 80 = 370; a `.bottom`-aligned view sits at 500.
        #expect(offset(alignment: 2, in: band) == CGSize(width: 0, height: -130))
    }

    @Test func anchorOffsetPutsTheCornerOnThePoint() {
        // \an7 + \pos(0.25, 0.5): top-leading corner onto (250, 250), from the container's (0, 0).
        #expect(offset(alignment: 7, position: CGPoint(x: 0.25, y: 0.5))
                == CGSize(width: 250, height: 250))
    }

    @Test func offsetHonoursTheVerticalShiftAndBottomLimit() {
        #expect(offset(alignment: 2, verticalShift: -50) == CGSize(width: 0, height: -130))
        #expect(offset(alignment: 2, bottomLimit: 300) == CGSize(width: 0, height: -200))
    }
}
